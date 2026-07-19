# Capture recipes + the `render_proof` predicate (ADR-0081)

UI goals get gamed by presence: a text/id predicate cannot tell "the designed
chrome renders" from "the id was pinned onto a stock component". The fix is a
**controller-produced screenshot** — a screenshot the converging worker produces
is a claim, not evidence (a cached build can lie). Capture recipes give a
goal-file a `[[capture]]` block the **controller** executes each observe pass into
a run-keyed evidence store the worker cannot write, and the `render_proof`
predicate consumes that capture so code that compiles but never renders cannot
converge.

See [ADR-0081](adr/0081-capture-recipes-run-evidence-store.md) for the full
rationale and its interlock with [ADR-0080](adr/0080-sealed-predicates-tamper-detection.md)
(sealed predicates): sealing makes the acceptance contract's *bytes* immutable;
captures make the predicate *inputs* controller-produced.

## The `[[capture]]` block

An array of named recipes (like `[[predicate]]`). The controller runs each one at
the start of every observe pass, in the workspace, writing the artifact into the
evidence store.

```toml
[[capture]]
name = "now_screen"                # required; the reference key predicates use
reset_cmd = "xcrun"                # optional; runs FIRST for a fresh environment
reset_args = ["simctl", "erase", "booted"]
launch_cmd = "node"                # required; the command that produces the artifact
launch_args = ["scripts/shot.js", "--route", "/now"]
output = "now_screen.png"          # required; the artifact FILENAME the recipe writes
post_launch_wait_ms = 2000         # optional; settle time before the artifact is read (default 0)
timeout_ms = 60000                 # optional; per-command hard deadline (default 60000)
```

| key | required | meaning |
|---|---|---|
| `name` | yes | the recipe's reference key (`capture = "<name>"` / `input = "capture:<name>"`). Unique within a goal. |
| `launch_cmd` / `launch_args` | `launch_cmd` yes | the command that produces the artifact. The injectable `CommandRunner` seam — a Playwright script, `xcrun simctl`, a headless-render CLI. |
| `reset_cmd` / `reset_args` | no | run FIRST for a fresh environment (e.g. erase a simulator so a cached install can't answer for current code). A failing reset fails the capture. |
| `output` | yes | the artifact FILENAME. Not a path — the controller resolves it into the store (below). |
| `post_launch_wait_ms` | no | settle time after launch before the artifact is read (default `0`). |
| `timeout_ms` | no | per-command hard deadline (default `60000`). |

### The recipe→artifact contract

`output` is a filename, not a path. The controller resolves it to the absolute
store destination and passes it to the recipe through two environment variables,
running the recipe with the **workspace as cwd** (so workspace-relative scripts
and builds resolve) while the artifact lands in **controller space**:

- `KAZI_CAPTURE_OUTPUT` — the absolute file the recipe must write.
- `KAZI_CAPTURE_DIR` — the recipe's per-capture store directory.

The recipe is responsible for writing its artifact to `KAZI_CAPTURE_OUTPUT`. A
minimal recipe is just a shell command:

```toml
[[capture]]
name = "now_screen"
launch_cmd = "sh"
launch_args = ["-c", "node scripts/shot.js --out \"$KAZI_CAPTURE_OUTPUT\""]
output = "now_screen.png"
```

## The evidence store

Captures are retained under the per-run sink tree, keyed by run id and observe
iteration:

```
<sinks_dir>/<run_id>/captures/<iteration>/<name>/<output>
<sinks_dir>/<run_id>/captures/<iteration>/<name>/capture.json   # provenance
```

`sinks_dir` defaults to `~/.kazi/runs` — **outside the workspace the worker
edits**. That directory separation is the write-protection: the worker operates on
the workspace; the evidence store is controller space it has no path to. The
`capture.json` sidecar stamps the recipe name, the resolved reset/launch command
lines, exit code, artifact `sha256` + byte size, and the timestamp — so a reviewer
(and a future visual judge) can verify which command produced which bytes. Artifact
bytes are referenced by path + hash, never inlined (leak hygiene, ADR-0034).

`kazi status <ref> --json` gains an additive `captures` array so a reviewer opens
the run and sees the pixels convergence was judged on:

```json
"captures": [
  {"iteration": 0,
   "artifacts": [
     {"name": "now_screen", "ok": true, "bytes": 51234,
      "sha256": "…", "artifact_path": ".../captures/0/now_screen/now_screen.png"}]}
]
```

## The `render_proof` predicate

`render_proof` consumes a capture by name and turns "it actually rendered" into an
objective predicate:

```toml
[[capture]]
name = "now_screen"
launch_cmd = "sh"
launch_args = ["-c", "node scripts/shot.js --out \"$KAZI_CAPTURE_OUTPUT\""]
output = "now_screen.png"

[[predicate]]
id = "renders"
provider = "render_proof"
capture = "now_screen"        # or: input = "capture:now_screen"
min_bytes = 1024              # optional; artifact size floor (default 1024)
min_distinct_bytes = 16       # optional; color-entropy proxy floor (default 16)
```

- `:pass` — the named capture succeeded AND the artifact exceeds the size floor
  AND a color-entropy floor (distinct byte values, a dependency-free "not a solid
  fill" heuristic).
- `:fail` — the capture failed (app crashed on launch, wrote nothing) or the
  artifact is blank / degenerate / a solid crash-screen fill. Real failing work:
  **a goal whose code compiles but never renders cannot converge.**
- `:error` — the capture machinery itself was unavailable (the goal declared no
  matching capture). Infra, never failing work (ADR-0002) — a mis-wired run does
  not dispatch a fixer.

The entropy floor is a conservative "not blank / not a crash fill" heuristic, not
a design judge; a real pixel-diff or visual-judge predicate (future work) consumes
the SAME controller capture.

## Live capture is the `CommandRunner` seam

Real capture needs a browser or simulator the CI shell does not have. kazi ships
the *seam* — `CommandRunner`-injectable recipes plus the controller / store /
`render_proof` plumbing — verified hermetically with a stub capture command
(`sh -c … > "$KAZI_CAPTURE_OUTPUT"`). A live browser/simulator capture is proven
the same way the `browser` provider's live path is: outside `mix test`.

# ADR-0081: Capture recipes + run evidence store — controller-owned captures so UI goals prove pixels, not file presence

## Status

Accepted

## Date

2026-07-19

## Context

UI goals are gamed by presence. A predicate that greps a workspace for an
accessibility identifier, a class name, or a file path cannot tell "the designed
chrome renders" from "the identifier was pinned onto a stock component and the
chrome was never built". In a consumer project a custom-tab-chrome goal converged
green exactly this way — the text predicate matched, the pixels never existed.
Text predicates fundamentally cannot distinguish *implemented* from *renders*.

Teams work around this with `custom_script` predicates that boot the app and
screenshot it, but that reintroduces the very asymmetry the controller exists to
remove:

- **The worker's harness effectively owns the capture path.** A `custom_script`
  that builds-and-screenshots runs in the workspace the worker controls, against
  whatever build/simulator/cache state the worker left behind. A stale or cached
  build can silently produce a *lying* screenshot — code the current source would
  fail passes because a cached install rendered. If the converging party produces
  the screenshot, the screenshot is a **claim, not evidence**.
- **The evidence evaporates.** The screenshots live in a temp dir that vanishes
  with the run. The convergence report carries no pixels, so the human merge gate
  has to re-boot and re-capture everything by hand to see what convergence was
  actually judged on.

This is the input-side twin of the problem [ADR-0080](0080-sealed-predicates-tamper-detection.md)
solved on the contract side. ADR-0080 makes the acceptance contract's *bytes*
immutable for the run (a worker cannot edit the thresholds or reference images).
But a worker who cannot edit the bar can still **forge the bar's inputs** if it
produces them: the seal protects the pixel-check manifest, not the screenshot the
manifest is compared against. The controller already enforces this separation for
predicate *evaluation* (kazi evaluates predicates; the worker does not); it does
not yet enforce it for predicate *inputs*.

## Decision

Add **capture recipes** and a **per-run evidence store**: the goal-file declares
named capture recipes; the **controller** (not the worker's harness) executes
them during observe passes; each capture lands in a run-keyed evidence store
outside the workspace that the worker cannot write; predicates consume captures
**by name** so a screenshot-consuming predicate gets a controller-produced,
provenance-stamped artifact rather than a worker-produced claim.

### 1. The `[[capture]]` goal-file block

Capture recipes are an **array of tables** (like `[[predicate]]`), each a named
recipe:

```toml
[[capture]]
name = "now_screen"            # required; the reference key for predicates
reset_cmd = "xcrun"            # optional; run FIRST for a fresh environment
reset_args = ["simctl", "erase", "booted"]
launch_cmd = "node"            # required; the capture command
launch_args = ["scripts/screenshot.js", "--route", "/now"]
post_launch_wait_ms = 2000     # optional; settle time before the artifact is read
output = "now_screen.png"      # required; the artifact filename the recipe writes
timeout_ms = 60000             # optional; hard deadline (default 60s)
```

- The recipe is a **command contract**, not app-specific: `reset_cmd`/`launch_cmd`
  are the same injectable `Kazi.Providers.CommandRunner` seam the browser and
  test-runner providers already use, so capture is harness-agnostic (a Playwright
  script, an `xcrun simctl` screenshot, a headless-render CLI) and hermetically
  stubbable in tests.
- `output` is a **filename**, not a workspace path: the controller resolves it
  into the run's evidence store (§3) and runs the recipe with that absolute
  destination, so the recipe writes *into controller-owned space*, never back into
  the workspace.
- A recipe with a `reset_cmd` runs it before `launch_cmd`, giving the "fresh
  environment per capture" the issue asks for (e.g. erase the simulator so a
  cached install cannot answer for current code).

### 2. Controller-side execution, keyed to the observe pass

Capture recipes execute in the loop's observe pass, at the **same precedence tier
as the ADR-0080 seal verify** — after the workspace-liveness precheck and the
seal verify (a vanished workspace or a tampered contract preempts capture), and
**before predicate evaluation**, so the resolved captures are available to every
predicate in that pass. The controller:

1. runs each recipe's `reset_cmd` then `launch_cmd` via `CommandRunner` in the
   workspace as cwd, with the artifact destination inside the evidence store;
2. records a **capture result** — `%{name, ok, exit, artifact_path, bytes,
   sha256, ran_at, reason}` — where `ok` is false when the command failed, timed
   out, or wrote no artifact;
3. threads the per-name capture-result map into `provider_context/2` as
   `context[:captures]`.

A failed capture is **never fatal to the loop** and never an error the worker can
exploit: it produces an `ok: false` capture result, which a consuming predicate
reads as failing work. Capture execution is off unless the goal declares
`[[capture]]`, so every existing goal is byte-identical.

### 3. The run evidence store — controller-written, workspace-external

Captures (and their provenance sidecars) are retained under the existing per-run
sink tree, keyed by run id and iteration:

```
<sinks_dir>/<run_id>/captures/<iteration>/<name>/<output>
<sinks_dir>/<run_id>/captures/<iteration>/<name>/capture.json   # provenance
```

`sinks_dir` defaults to `~/.kazi/runs` (the same root as the events/transcript
sinks), which is **outside the workspace the worker edits**. That directory
separation *is* the write-protection: the worker's harness operates on the
workspace tree; the evidence store is controller space the worker has no lease
on. The store is named distinctly (`Kazi.Sink.Captures`) to avoid collision with
the unrelated per-finding `Kazi.Evidence` diagnostic type (ADR-0041).

The provenance sidecar (`capture.json`) stamps the recipe name, the resolved
`reset`/`launch` command lines, exit code, artifact `sha256` + byte size, and the
capture timestamp — so a reviewer (and a future visual judge) can verify *which
command produced which bytes*, and the convergence report can show before/after
pairs when a baseline capture is declared. The sidecar never embeds workspace
secrets; command lines are recorded, artifact bytes are referenced by path +
hash, not inlined (ADR-0034 leak hygiene).

`kazi status <ref> --json` gains a per-iteration `captures` array
(`{name, ok, artifact_path, sha256, bytes}`), mirroring the additive `landed`
field, so a reviewer opens the run and sees the pixels convergence was judged on.

### 4. Predicates consume captures by name

A predicate references a capture with an `input` of the form `capture:<name>`
(equivalently a `capture = "<name>"` config key). The provider resolves it
against `context[:captures]` — it receives the **controller-produced** artifact
path and provenance, never a workspace path it or the worker chose. This is the
generic seam; the first consumer is §5.

### 5. The built-in `render_proof` predicate

`render_proof` is a minimal, always-available provider that turns "it actually
rendered" into an objective predicate:

- `:pass` iff the named capture `ok` AND the artifact exceeds a **byte-size floor**
  AND a **color-entropy floor** (distinct-color / non-uniformity heuristic) — an
  image that is blank, a solid crash-screen fill, or a truncated write fails.
- `:fail` (real failing work) when the capture failed, the app crashed on launch,
  or the artifact is blank/degenerate — so a goal whose code compiles but crashes
  or renders nothing **cannot converge**.
- `:error` (infra, not failing work) only when the capture machinery itself could
  not run (e.g. the recipe command is missing) — never conflated with `:fail`
  (ADR-0002).

The floors are conservative defaults (overridable per predicate) chosen to reject
blank/crash frames without demanding a specific design; a real pixel-diff or
visual-judge predicate (future work) consumes the SAME controller capture.

### 6. Interplay with ADR-0080 (seal) and ADR-0042 (enforcement)

These three layers compose into "the worker can neither edit the bar nor forge
its inputs":

| Layer | Protects | Mechanism |
|---|---|---|
| ADR-0042 `read_only_paths` | agent write lease | advisory hash flag |
| ADR-0080 seal | contract **bytes** (thresholds, reference images) | fatal `tampered` on mismatch |
| ADR-0081 captures (this) | predicate **inputs** (the screenshot itself) | controller produces them, in workspace-external store |

The `[[capture]]` block is part of the goal-file, so it is **implicitly sealed**
whenever sealing is enabled — a worker cannot quietly edit a recipe to point the
capture at a cached build. The evidence store is controller-written and lives
outside the workspace, so it is not a sealed input and needs no seal entry: the
worker has no path to it at all.

## Consequences

- A UI goal that declares a `render_proof` predicate over a controller capture
  cannot converge on file presence: the code must actually launch and render, or
  the predicate is `:fail`. The custom-tab-chrome gaming class is closed for goals
  that opt in.
- The convergence report and `status --json` carry the pixels convergence was
  judged on, run-keyed and provenance-stamped, so the human merge gate reviews
  evidence instead of re-capturing by hand.
- Backward-compatible: a goal with no `[[capture]]` block runs byte-identically;
  capture execution and the evidence store are inert until declared.
- Capture execution is only as trustworthy as the recipe's freshness discipline;
  the ADR ships the `reset_cmd` lever, not an enforced clean-room. A recipe that
  omits its reset can still capture a stale environment — that is an authoring
  choice the provenance sidecar makes auditable, not a silent default.
- **Live-capture infrastructure is out of hermetic scope.** Real capture needs a
  browser/simulator the CI shell does not have; kazi ships the *seam*
  (`CommandRunner`-injectable recipes) and the controller/store/predicate
  plumbing, verified hermetically with a stub capture command. A live browser or
  simulator capture is proven the same way the `:browser` provider's live path is
  — outside `mix test` — and is explicitly a follow-up, not faked green here.
- Follow-up: a real pixel-diff / visual-judge predicate over captures; baseline
  before/after pairing surfaced in the dashboard drill-in; and a per-recipe
  clean-room enforced by the controller rather than author-declared.

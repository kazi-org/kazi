# kazi devlog

Session findings, dogfood results, and benchmarks. Append-only; newest entries
at the top. For invariants/landmines see `docs/lore.md`; for decisions see
`docs/adr/`.

## 2026-06-26 — T30.4 LIVE escalation dogfood: cheap tier converged, ladder did not climb (honest negative) + a `max_iterations=1` landmine

The live dogfood for the ADR-0035 escalate-on-stuck ladder (UC-045, UC-033),
run against the **released v1.64.1 macOS binary** driving the **real claude
harness** (Claude Code 2.1.193) — no source build, no stubs.

**Fixture (self-contained, opaque, non-gameable).** A `custom_script` goal whose
predicate runs a candidate `solution.py` and compares the **sha256** of its
printed integer to a stored digest. The hash is one-way, so the oracle yields
only pass/fail and leaks nothing — the model cannot game it by reading the
checker; it must compute the value. The problem (chosen non-memorizable, not the
famous Project-Euler bound): the sum of every `n` with `1 ≤ n < 1_000_000` that is
a palindrome simultaneously in base 10, base 2, AND base 8 (no leading zeros) —
answer `610`. Multi-step base conversion is an honest correctness trap.

**Ladder (per AGENTS.md / ADR-0035):** `claude-haiku-4-5 → claude-sonnet-4-6 →
claude-opus-4-8`, each rung one `kazi apply --harness claude --model <rung> --json`
on the same slice; escalate when `status` is `stuck`/`over_budget`.

**Released-CLI gap found before the run.** `kazi apply` exposes no
`--permission-mode`/`--allowed-tools` flag, and the goal-file `[harness]` table
accepts only `id`/`model`/`command`. With the default permission mode the inner
`claude` runs non-interactively and **applies zero edits** — a first probe ran
two Haiku iterations, spent $0.112, and wrote no file (terminal
`status: over_budget`, predicate still `fail`). To grant the inner agent the
file-edit permission the recipe assumes (the T19.7 repro used
`permission_mode: :bypassPermissions`), the run set `[harness] command` to a
one-line wrapper (`exec claude --dangerously-skip-permissions "$@"`). With that,
a trivial `hello.txt` smoke converged ($0.049). **Follow-up:** surface
`permission_mode` on the released CLI (or default it for the claude harness),
else a vanilla `kazi apply --harness claude` makes no edits and every code goal
terminates `over_budget`.

**Run A — the real escalation attempt (`max_iterations = 2` per rung).**

```
kazi apply ./goal.toml --workspace ./ws --harness claude --model claude-haiku-4-5 --json
```

Rung 1 (Haiku) terminal result: `status: converged`, predicate `pass`,
`iterations: 2`, `cost_usd: 0.0768584`, `wall_clock_s: 39.3`. The iteration
trace is `iter=1 failing=[…] → iter=2 failing=[]`: Haiku got the first dispatch
wrong, self-corrected on the second, and converged. The written `solution.py`
was independently verified to print `610` (oracle exit 0). **The ladder never
advanced past rung 1 — escalation did NOT fire, and was not needed.**

This reproduces the T19.7 / T36.5 finding on a fresh, harder, opaque-oracle
fixture via the released binary: a self-verifying inner harness (bash + the
predicate oracle across iterations) converges a within-reach slice on the
cheapest tier, so the model-escalation ladder rarely climbs in practice. A
genuine capability-driven climb was **not observed and not manufactured** — the
opaque sha256 oracle plus the honesty bar preclude staging a fake stall.

**Run B — a `max_iterations = 1` probe surfaced a loop-accounting landmine.**
Rerun with a one-dispatch budget, rung 1 (Haiku) reported `status: over_budget`,
`next_action: raise_budget`, `budget_spent.exceeded: "max_iterations"`, predicate
`fail` — i.e. exactly the ladder's escalation trigger. **But the `solution.py`
Haiku wrote in that single dispatch already printed `610` (correct).** Haiku
*solved* it; the `over_budget` is an artifact: kazi's observe→act loop needs a
**final re-observation after the last action** to record the pass, and
`max_iterations = 1` spends its only iteration on the act, terminating with the
*pre-dispatch* failing vector. **Landmine:** `max_iterations = 1` can never
converge any goal, and a one-dispatch budget over-reports "stuck". An
`over_budget`/`stuck` result must be read **together with the predicate vector /
real state**, never as standalone proof the model failed — and an escalation
recipe must give each rung at least 2 iterations (act + confirm). Escalating the
model here would have been escalating against a budget artifact, not a capability
limit, so it was not done.

**Cost (every figure from a captured `cost_usd` envelope).** Auth/permission
probes ≈ $0.21 (incl. the $0.112 no-edit probe and the $0.049 smoke); Run A
$0.0769; Run B rung 1 $0.0788. **Total observed ≈ $0.37**, far under any ceiling
(the fixture is deliberately tiny).

**Verdict (honest).** The escalation **trigger signal** is live-verified
sufficient on the released binary: a non-converged rung emits
`status`/`next_action`/`budget_spent.exceeded` + the failing `predicates[]`
exactly as ADR-0035 / T30.3 specify, and rung dispatch on the released binary
works. The **model-escalation ladder did not climb**, because the cheap tier
(Haiku) converged unaided — a truthfully-reported negative, which the T30.4
acceptance explicitly permits. The ladder's climb logic remains pinned by
T19.7's worst-case row + the `Kazi.Context.Escalation` unit tests; a live
capability-driven climb needs a slice genuinely beyond the cheap tier's reach,
which a self-verifying harness rarely yields and which was not gamed here.

## 2026-06-25 — T16.6 LIVE: the installed kazi skill drives a goal end to end (plan → approve → apply) on released v1.46.2

The closing live proof for T16.6 (UC-034): a Claude Code user who runs
`kazi install-skill` gets a skill that drives kazi to convergence with **no
further instruction**. Exercised against the **released v1.46.2 macOS binary**
driving the **real claude harness** — no source build, no stubs.

**Step 1 — install the skill (non-invasive).** `kazi install-skill --dir
<scratch>` writes exactly ONE file, `SKILL.md`, into the target dir (the `--dir`
flag is the documented test/scratch injection point; default is the global
skills dir, left untouched here).

**Step 2 — verify the installed skill teaches the CURRENT surface.** Read the
generated `SKILL.md` and cross-checked every `kazi <cmd>` it names against `kazi
help --json`:
- It routes the four current verbs — `plan` (author predicates), `apply`
  (the reconcile loop), `status` (read state), `adopt` → `kazi init` — plus
  `approve` / `reject` / `list-proposed`, all REAL commands.
- It explicitly states the legacy verbs `run`/`propose` were REMOVED and to use
  `apply`/`plan`; it does NOT instruct the agent to run a removed verb as a live
  command.
- It carries the full `plan → approve → apply` recipe, the two-tier economics,
  the escalation ladder, and a "confirm the live surface with `kazi help --json`"
  instruction — enough for an agent to drive a goal with no other guidance.
  VERDICT: the skill content is correct and current.
- One drift FINDING (not in the skill file): the `install-skill` **stdout
  banner** the binary prints after writing still reads "propose --json → approve
  --json → run --harness <cheap>" — the removed verbs. Cosmetic (an agent reads
  `SKILL.md`, not the banner), but it should be updated to `plan → approve →
  apply` for honesty. Logged for a follow-up.

**Step 3 — drive a fixture goal following ONLY the skill's flow.**
1. `kazi plan "create a file named hello.txt … exact contents … Hello, kazi!"
   --workspace <ws> --yes --json` → drafted a proposal
   (`prop-create-a-file-named-hello-txt-…`) with **1 usable `custom_script`
   predicate**: `cmd="sh"`, `args=["-c","printf 'Hello, kazi!\n' | diff -
   hello.txt"]`, `verdict=exit_zero`. The prose on-ramp parsed cleanly — NO
   "proposal is not valid JSON" error (the T26.8 fix is live on v1.46.2).
2. `kazi approve <ref> --json` → `{"status":"approved"}`.
3. Transcribed the approved predicate verbatim into a create-mode goal-file
   (`mode="create"`, the predicate byte-for-byte), then `kazi apply <goal-file>
   --workspace <ws> --harness claude --json` → **`status: converged`** in **2
   iterations / 16.2s**, predicate `verdict: pass`. Workspace artifact
   `hello.txt` == bytes `Hello, kazi!\n` (13 bytes), exactly the predicate.
   `economy`: 1 converged predicate, $0.17, 39,079 tokens.
4. `kazi status create-a-file-named-hello-txt --json` → `kind:run,
   converged:true` — the read-model reflects the run. All four skill verbs
   exercised green.

**Verdict: the dogfood PASSES for a user on the released binary.** T16.6 → `[x]`.

**Two honest caveats.**
1. A freshly-installed skill registers for a NEW Claude Code session; this
   verification followed the skill's documented flow with the released v1.46.2
   binary by hand, which is the faithful equivalent of an agent reading that
   skill and driving the same commands — not a screenshot of a separate session.
2. **The stale Homebrew tap is the residual gate for `brew install` users.**
   `brew install kazi-org/tap/kazi` currently ships **1.41.1**, which has the
   BROKEN prose on-ramp (the `kazi plan` JSON-parse bug fixed in T26.8 and
   shipped in v1.46.x). So a brew-install user who runs `install-skill` and
   follows the skill TODAY fails at the very first step (`plan`) until the tap
   is bumped to ≥1.46.2. The skill itself is correct and version-agnostic; the
   gate is the packaged binary, not the skill. Bumping the tap on release is the
   outstanding fix (see `docs/lore.md` L-0019).

Note: T16.6's plan-line acceptance text predates the verb rename and reads
"propose → approve → run"; the real, current flow is **plan → approve → apply**
(`kazi help --json`), which is what was driven here.

## 2026-06-26 — T26.8 LIVE VERIFIED: the full `plan → approve → apply` on-ramp converges on released v1.46.2

The closing live proof for T26.8. Both code fixes (L2 harness-parse PR #634/v1.46.1,
L3 drafting-prompt schema PR #638/v1.46.2) were exercised end to end against the
**released v1.46.2 macOS binary** driving the **real claude harness** — no source
build, no stubs.

**The chain.**
1. `kazi plan "Create a file named status.txt in the workspace whose contents are
   exactly the text: ready" --yes --json` → drafted a proposal
   (`prop-create-a-file-named-status-txt-…`) with **1 usable `custom_script`
   predicate** whose config keys are the canonical `cmd` / `args` / `verdict` /
   `pass_codes` — `cmd="sh"`, `args=["-c","test -f status.txt && printf '%s' ready |
   cmp -s - status.txt"]`. No invented `script`/`interpreter`. (Pre-fix this returned
   "proposal has no predicates".)
2. `kazi approve <ref>` → `{"status":"approved"}` — the goal LOADS through the same
   loader `approve` uses. (Pre-L3-fix this failed: `requires a non-empty string "cmd"`.)
3. `kazi apply <goal-file> --harness claude` → **`status: converged`** in **2
   iterations / 14.9s**, predicate `verdict: pass`, and `status.txt` == bytes `ready`
   (5 bytes, no trailing newline). `economy`: 1 converged predicate, $0.159, 39,947
   tokens.

**One honest gap noted (not a T26.8 blocker).** `approve` does NOT auto-materialize a
goal-file; the operator captures the approved predicates "as a file you can version
and re-run" (README's documented step — `approve`'s own output says "The goal is now
runnable: kazi apply <goal-file>"). For this verify the goal-file was the approved
predicate transcribed verbatim (byte-for-byte the drafted `cmd` config), so the
chain proven is faithful. A future ergonomics task could let `kazi apply` consume an
approved proposal-ref directly (or have `approve --out goal.toml` write the file),
removing the manual transcription. Filed as an observation, not part of T26.8.

T26.8 is now `[x]`. This unblocks T16.6 (Claude Code drives kazi via the skill) and
T26.6 (live subsumption gate), both of which depended on a working prose on-ramp.

## 2026-06-25 — T26.8 layer 2: the drafted custom_script config SHAPE blocks `approve` (invented `script`, not `cmd`)

PR #634 fixed the harness PARSE layer (claude's stderr warning broke the envelope —
see the entry below). A LIVE run on the RELEASED v1.46.1 binary then exposed the
NEXT layer of the same "drafted-proposal SHAPE" bug — one step past parsing.

**The live symptom.** On v1.46.1, `kazi plan "Create a file named greeting.txt …
contents exactly: hello world" --yes --json` now SUCCEEDS at drafting and returns a
proposal with a predicate (the parse fix works). But `kazi approve <ref>` then FAILS:

    could not approve …: the stored goal no longer loads: "custom_script predicate
    \"greeting_file_exists_with_exact_contents\" requires a non-empty string \"cmd\""

**Root cause.** The drafting harness (claude), told only the provider NAMES, GUESSES
each predicate's `config` shape — and guesses wrong. It drafted a `custom_script`
config with an INVENTED shell-script shape:
`{"script": "<bash>", "interpreter": "bash", "working_dir": ".", "expected_exit_code": 0}`.
But kazi's REAL `custom_script` schema (what `kazi schema custom_script` prints,
sourced from `Kazi.Predicate.Schema`) requires `cmd` (ONE executable) plus optional
`args`/`verdict`/`env`/… — there is NO `script`/`interpreter`/`working_dir`/
`expected_exit_code`. So every drafted `custom_script` predicate is structurally
invalid and the on-ramp dies at `approve` (the loader validates `cmd` at load).
The captured fixture `test/fixtures/harness/claude_authoring_draft_stdout.txt` shows
this exact invented shape across all three of its `custom_script` predicates.

**The fix (option (a): pin the prompt).** `Kazi.Authoring.build_prompt/2` now EMBEDS
the authoritative per-provider config contract, rendered straight from
`Kazi.Predicate.Schema` (the SAME single source `kazi schema <provider>` prints — no
hand-duplicated field list to drift). Each documented provider gets its required/
optional keys (required marked `*required*`) plus the schema's own example config,
and `custom_script` gets an explicit pin: MUST use `cmd` (put a shell line in
`cmd:"sh", args:["-c","<line>"]`), MUST NOT use `script`/`interpreter`/`working_dir`/
`expected_exit_code`. Prompt-first (not decoder-aliasing) so the harness emits VALID
configs at the source. Confirmed: a drafted `custom_script` predicate using `cmd` now
LOADS through the same loader `approve` uses (no "requires a non-empty string cmd").

**Tests.** `authoring_test.exs`: a `cmd`-shaped `custom_script` parse → serialize →
`Loader.from_map` LOADS (Tier-0); a stub draft in the fixed shape `propose`s and the
persisted goal LOADS end-to-end (Tier-2); `build_prompt/2` output contains the
`custom_script` contract (`cmd … *required*`) and forbids `script`. Full suite green.

**Remaining gate.** Live re-verify on the RELEASED binary — `kazi plan "<idea>"` →
`kazi approve <ref>` → `kazi apply` converges — is a POST-RELEASE step (this fix must
merge + release first). T26.8 stays `[ ]` until that live chain is observed.

## 2026-06-25 — T26.8 ROOT CAUSE found by live capture: claude's stderr warning broke the envelope parse, not the proposal shape

Built kazi from source and drove ONE real `claude -p --output-format json` authoring
draft (idea: "a CLI tool that prints the current git branch name") to capture the
exact bytes, instead of guessing the shape. The capture overturns the prior
hypothesis (PR #623 assumed a proposal-SHAPE problem and added `goal`/`proposal`/
`spec` wrapper-key parsing). The real bug is one layer DOWN, in the harness adapter.

**What real claude returns.** The adapter result map was
`%{exit: 0, command: "claude", output: <stdout>, workspace: "."}` — NO `:result`,
NO `:tokens`, NO `:cost_usd`. The `output` was:

1. a leading line on STDERR — `Warning: no stdin data received in 3s, proceeding
   without it. ...` (claude waits 3s for stdin under `System.cmd`, then warns), which
   the adapter merges into stdout via `cmd_opts`'s `stderr_to_stdout: true`; then
2. the normal `{"type":"result", ..., "result":"<the proposal JSON as a string>", ...,
   "usage":{...}, "total_cost_usd":...}` envelope.

**Why authoring failed.** `Kazi.Harness.Profiles.Claude.parse/1` did
`Jason.decode(output)` on the WHOLE stdout. The warning prefix made that decode fail,
so `parse/1` returned `%{}` and the adapter merged NOTHING — dropping `:result`,
`:tokens`, `:cost_usd`, `:usage` on every run that hit the warning. With no `:result`,
authoring's `proposal_payload/1` fell back to the raw `:output`, whose first-`{`..last-`}`
span is the OUTER envelope object (`type`/`result`/`usage` keys) — no top-level
`predicates` — so `build_predicates` reported "proposal has no predicates". PR #623's
wrapper keys never matched because the real wrapper key is `result` and its value is a
JSON STRING, not a nested map. This also explains why `kazi apply` "works" while
`kazi plan` doesn't: apply re-runs predicates to judge done and lets the budget fall
back to a token ESTIMATE (ADR-0008), so the dropped `:result`/token fields are
invisible there; authoring is the only path that needs the structured `:result`.

**The fix (one line of behavior).** `Claude.parse/1` now narrows to the JSON object
span (first `{` .. last `}`) BEFORE `Jason.decode`, so a stderr-noise-prefixed
envelope still parses. A clean envelope is byte-identical (the span IS the whole
object — golden conformance unchanged); output with no braces or genuinely malformed
JSON still degrades to `%{}`. This restores `:result` (→ authoring builds the goal)
AND `:tokens`/`:cost_usd` (→ token/cost accounting, silently broken before whenever the
warning appeared). No change to the authoring parser or the drafting prompt was needed;
PR #623's speculative wrapper-key code is left in place as harmless defense-in-depth.

**Verified against real bytes (source build).** The captured stdout is checked in as
`test/fixtures/harness/claude_authoring_draft_stdout.txt`. Re-running the fixed
`Profile.parse(:claude, <real bytes>)` yields `:result` + `:tokens` + `:cost_usd`, and
`Kazi.Authoring.parse_proposal/2` on the recovered `:result` builds **6 acceptance
predicates** (`custom_script`×3, `test_runner`, `coverage`, `static`) — the
`custom_script` predicates survive (the E32 provider map, already fixed in PR #623 by
delegating to `Loader.provider_kinds/0`, is confirmed correct). Tests:
`conformance_test.exs` pins the noise-prefixed real-envelope parse;
`authoring_test.exs` drives `propose/2` through a stub returning the real adapter
result and asserts ≥1 predicate incl. `custom_script`.

**Remaining gate.** Live verify on the RELEASED binary — the full `kazi plan "<idea>"`
→ `kazi approve <ref>` → `kazi apply` chain — is a POST-RELEASE step (this fix must
merge + release first). Pre-merge verification was done against the source build on
real claude bytes as above.

## 2026-06-25 — LIVE dogfood frontier is headless-unblockable; T26.8 prose-drafting still broken live

A headless `/apply --pool` session checked whether the remaining LIVE dogfood tasks
are operator-only or actually drivable from a non-interactive session, using the
`claude` CLI harness (v2.1.193) + the RELEASED binary `kazi v1.45.0` (downloaded
from the GH release, sha-verified) + agent-browser.

**Core enabler PROVEN (real reconcile).** Authored a minimal create-mode goal — one
`custom_script` predicate, `bash -c 'test -f hello.txt && [ "$(cat hello.txt)" = ok ]'`,
`verdict = exit_zero`, failing at t0 (no file). `kazi apply <goal> --workspace <ws>
--harness claude --json` converged in **2 iterations / 15.3s**: iter1 vector `fail`
(exit 1) → claude harness created `hello.txt` → iter2 `pass` (exit 0) →
`{"status":"converged","iterations":2,...}`, `enforcement.active=true`,
`gaming_events=[]`. `hello.txt` verified = `6f6b` (`ok`, 2 bytes, no newline). So the
goal-file → claude → objective-true loop runs fully headless on the released binary.
That unblocks the goal-file dogfoods (T20.11, T21.12, T23.9, T30.4, T31.7, T32.11,
T35.10) and — with the LiveView feature built + agent-browser — the dashboard tasks
(T20.8, T21.9) and the live-site leg of T25.10.

**T26.8 LIVE FINDING — the prose on-ramp is still broken.** Drove `kazi plan "<idea>"`
on v1.45.0 (which contains PR #623). `--json` returns a STRUCTURED clarification
request (`missing: live-target, scope` — progress over the old raw parse error), but
`--yes` best-effort STILL returns `{"error":"... proposal has no predicates"}`. So
PR #623's robust-to-multiple-shapes parser does NOT match what real claude actually
emits — exactly the risk the fixer flagged (it had no live capture and guessed). The
real fix per the original T26.8 recipe: source build + a temporary `IO.inspect` in
`Kazi.Authoring.drive_harness` (authoring.ex:405) to capture ONE raw claude draft,
then parse THAT shape (or pin it via the drafting prompt). T26.8 stays `[ ]`; it also
blocks T16.6/T26.6. Plan updated (master Progress Log + E26.md T26.8 note) so other
sessions claim the now-unblocked dogfoods and avoid re-deferring them as "operator-only".

## 2026-06-25 — Doc-lifecycle encoded as a kazi standing goal (T31.6 / ADR-0036)

Shipped `priv/examples/doc_lifecycle.goal.toml`: the ADR-0036 documentation
lifecycle expressed as a committed kazi STANDING goal-file kazi can reconcile,
built ENTIRELY on the E32 generic providers — no bespoke predicate engine and no
doc-specific code in kazi core (the ADR-0036 reject held).

Predicate composition: six doc-freshness checks are `custom_script` predicates
(ADR-0040) WRAPPING the T31.4 scripts — `check_a/b/c/d` plus the subsumed (E)
README↔site and (F) skill↔CLI coherence checks — each with `verdict = "exit_zero"`
since the checker's exit code already means pass/fail. Two GRADIENTS are `ratchet`
predicates (ADR-0041 envelope-v2): a doc-coverage ratchet (% commands documented,
`higher_better`, baseline `stored`) and a stale-`[x]`-task count ratchet (to `0`,
`lower_better`). The two ratchet metrics are thin new wrapper scripts
(`metric_doc_coverage.sh`, `metric_stale_tasks.sh`) reading the SAME command
surface / offender set as predicates (a)/(d), each printing one bare number to
stdout. An `[enforcement]` block (ADR-0042) marks the checkers + lifecycle tools
`read_only_paths` so an agent can't edit a grader to fake a green.

Landmine re-confirmed (L-0012 sibling): a bare relative `cmd` like
`.github/scripts/...sh` is NOT runnable — `System.cmd` resolves the executable
against PATH, not the workspace, so it fails `:enoent`. Fix: `cmd = "bash"`,
checker in `args` (bash resolves the script arg against `--workspace`). Verified
empirically before settling the format.

Validation (headless bar = load + predicate-eval, no live multi-minute reconcile):
`test/kazi/goal/doc_lifecycle_goal_test.exs` pins load-as-standing, the 6+2 kind
composition (no other kinds), zero-stub (every wrapper points at a real script),
and a real `:pass`/`:fail` (never `:error`) eval. Manual full-vector eval today:
`adr-refs-exist`, `readme-site-coherence`, `skill-cli-coherence`, and
`doc-coverage-ratchet` (score 66.7) PASS; `plan-trimmed`, `commands-in-readme`,
`no-dead-command-refs`, and `stale-tasks-ratchet` (score 121) FAIL — exactly the
drift on main today that the live dogfood (T31.7) drives to green. Layers wired:
1 (trim, auto) + 3 (freshness, auto) auto, 2 (extract, human-confirm) keeps its
gate.

## 2026-06-25 — Gated knowledge extraction shipped (T31.3 / ADR-0036 Layer 2)

Shipped `.github/scripts/extract_knowledge.py` + `test_extract_knowledge.py`, the
Layer-2 propose-then-confirm pass that composes AFTER T31.2's `trim_plan.py`.
Once `trim_plan.py --apply` archives a fully-done, released epic verbatim under
`docs/plans/archive/`, `extract_knowledge.py --latest` (or `--epic <file>`) reads
that archived block, finds the durable nuggets, and routes each to its tier per the
ADR-0036 map: invariant/landmine -> `lore.md` (next `L-NNNN`), finding/benchmark ->
`devlog.md` (dated, newest-first), decision -> a NEW `docs/adr/NNNN-*.md` with
`Status: Proposed`, architecture -> `concept.md` (NOT design.md). Nuggets are found
by explicit `Nugget(<class>):` annotations, class hashtags, or a keyword heuristic.

Two invariants make it the safe LLM-shaped step: it NEVER writes to or removes from
the archive (so the archive is the lossless backstop — a mis-route loses no
knowledge), and it dry-runs by default, printing the routing for review; `--apply`
is the human-confirm gate. Each written edit carries a `kx:<sig>` provenance marker,
so re-running is idempotent. Wired the fixture test into `oss-gates.yml` alongside
`test_trim_plan.py` (report-only; CI never auto-writes docs). Together T31.2 (trim,
lossless, mechanical) + T31.3 (extract, gated, lossless backstop) are Layers 1+2 of
the ADR-0036 doc lifecycle; T31.6 will drive both as a kazi standing goal.

## 2026-06-25 — T26.8: `kazi plan` drafted-proposal SHAPE made robust + E32 providers mapped (PR #623, live-verify deferred)

Worked T26.8 under `/apply --pool` (headless). The on-ramp step-1 blocker after
T26.7: a drafted proposal PARSES, but `build_predicates` reported "proposal has no
predicates" because the predicate array wasn't at the documented top level.

**Diagnosis (two distinct gaps).**
  1. *Shape.* `parse_proposal/2` read only the top-level plural `"predicates"` key.
     Real claude routinely returns the goal nested under a wrapper
     (`{"goal": {…}}` / `"proposal"` / `"spec"`) or as a goal-file-shaped object
     using the singular `"predicate"` array — so `Map.get(map, "predicates")` was
     `nil` and `build_predicates(nil)` → "proposal has no predicates".
  2. *Provider catalog.* Authoring kept its OWN 4-entry `@provider_kinds`
     (`test_runner`/`http_probe`/`prod_log`/`browser`) that omitted the entire E32
     catalog, so a drafted/caller predicate naming `custom_script` (or `static`,
     `ratchet`, `metrics`, `coverage`, `property`, `mutation`, `cve`) was dropped by
     `provider_kind/1` → "no usable predicate in proposal".

**Approach: robust-to-multiple-shapes (NOT a live-captured shape).** Headless, so a
multi-minute live `claude` capture wasn't reliable; per the task's sanctioned
fallback the parser was made robust to the plausible shapes (a durable fix
regardless of which exact shape claude emits):
  - `unwrap_proposal/1` descends into a single `goal`/`proposal`/`spec` wrapper when
    the top level carries no predicate array;
  - `extract_predicates/1` accepts both the plural `"predicates"` and the goal-file
    singular `"predicate"` array;
  - `predicate_config_source/1` takes config from a nested `"config"` map, else
    collects the non-reserved sibling keys (the goal-file convention) so that
    shape's config survives;
  - provider mapping now defers to `Kazi.Goal.Loader.provider_kinds/0` — newly
    exposed as the single source of truth — so the loader's full catalog is
    recognised and the two catalogs cannot drift again. Malformed input still
    errors cleanly.

**Validation.** `mix compile --warnings-as-errors` + `mix format --check-formatted`
clean; `authoring_test.exs` 38 passed (6 new fixtures: wrapper-nested,
goal-file-singular with sibling config, custom_script survival, wrapped+modern
combo); full suite 2240 passed (the lone foreground failure was the known
timing-flaky `Scheduler.SupervisionTest`, greens on re-run).

**REMAINING GATE (why T26.8 stays `[ ]`).** The acceptance still requires LIVE
verification on the released binary — `kazi plan "<idea>"` → `kazi approve <ref>` →
`kazi apply` converges (the full chain, which also unblocks T27.8). A headless agent
cannot cut a release or drive a live multi-minute claude session, so that leg is
DEFERRED to a live session. The code/tests/docs landed; the live verify did not.

## 2026-06-25 — Session handover: release/tap pipeline fixed live; `kazi plan` drafting half-fixed (T26.7 done, T26.8 next)

Long `/apply --pool` + operator-directed session. Shipped + verified live this session:

- **E32 wave** (predicate catalog / evidence-v2): T32.1b through T32.10 shipped + released; plan marked.
- **Docs/site reframed to the human -> Claude -> kazi -> Claude on-ramp**: README, website (live), `concept.md` Section 0, the GitHub repo description, and the page `<title>`/OG meta -- all lead with the benefit ("you never run kazi yourself; Claude does"); "the outer/reconciliation loop for coding agents" demoted to an under-the-hood note (kept for SEO/coherence). Fixed 9 Astro newline-stripping spacing bugs (the `Afterkazi` class -- text on one line + an inline `<code>`/`<strong>` on the next loses the space; fix with an explicit `{" "}`). Removed the unexplained Context7 analogy from user-facing copy. All verified on https://kazi.sire.run.
- **RELEASE/TAP PIPELINE fixed end to end (the headline).** Root cause: the Burrito binary boots the CLI before supervising `Kazi.Repo`, and `migrate_read_model` (standalone branch) used `Ecto.Migrator.with_repo` -- migrate-then-STOP -- so the read-model was never left running. Every read-model command crashed the binary ("could not lookup Ecto repo Kazi.Repo because it was not started"): `kazi status`/`list-proposed`/`approve` AND the `kazi mcp` `kazi_status` tool. The T33.4 MCP release-smoke calls `kazi_status` BEFORE asset upload, so it failed on EVERY release since the smoke landed -> 0 binaries since v1.20.0 -> `brew install` frozen at the broken 1.20.0. Fix: PR #613 (start + KEEP the repo running in the standalone branch), released v1.41.1; the chain self-healed (build smoke passed, `tap-bump` auto-pushed the formula -- `HOMEBREW_TAP_TOKEN` was configured all along; the chain had been FAILING on the smoke, not skipping). Also added PR #611 (a `workflow_dispatch` manual build trigger as a recovery hatch). `brew upgrade` -> 1.41.x VERIFIED: `status`/`list-proposed`/`mcp` no longer crash.
- **`kazi plan` drafting -- JSON layer (T26.7, PR #617):** `decode_proposal/1` now extracts the JSON object from fenced/prose harness output before `Jason.decode`. Merged + 2 Tier-2 tests.

**OPEN THREAD -> T26.8 (epic E26).** `kazi plan "<idea>"` still fails end to end: after T26.7 the harness output PARSES but has no usable top-level `predicates` array ("proposal has no predicates"). `kazi apply <goal-file>` works; only prose-idea DRAFTING is broken. Next-step recipe:
  1. Capture ONE raw `claude` draft. It drives a MULTI-MINUTE claude session, so do NOT cap at 3 min (the diagnostic timed out) -- use a >=10-min timeout or a background run. Tee the harness result with a temporary `IO.inspect` in `Kazi.Authoring.drive_harness` (lib/kazi/authoring.ex:405; REVERT after).
  2. Compare claude's actual shape against the expected `{name, predicates:[{id, provider, description, config}], rationale}` (`build_prompt/2`, authoring.ex:366).
  3. Fix the smaller of: tighten the drafting PROMPT to pin the shape, or make `build_predicates`/`decode_proposal` accept what claude emits.
  4. Also map the E32 providers (`custom_script`/`:static`/...) into authoring `provider_kind` (currently omitted -> a drafted predicate naming one is silently dropped).
  5. Verify LIVE on the released binary: `kazi plan "<idea>"` -> `kazi approve <ref>` -> `kazi apply` converges (this also unblocks T27.8's blocked plan->approve leg).

Durable details are in memory: `kazi-plan-drafting-broken`, `homebrew-tap-stale-readmodel-crash`, `adoption-docs-consolidated-e25`.

## 2026-06-25 — context-tier + tool-surface benchmark (T36.5): surface ON is a real ~2× token win; the tier knob is net-neutral on a within-reach fixture

The two inner-harness knobs ADR-0047 gave kazi — the context TIER
(`Kazi.Context.Tier` 0–4: how MUCH context a dispatch assembles, T36.3) and the
tool-SURFACE (`Kazi.Harness.DispatchSurface` `:minimal`/on vs `:ambient`/off: how
many tool/MCP schemas the harness loads, T36.2) — measured LIVE so the defaults
are set from data, not a guess (T36.5, ADR-0047; verifies UC-033). Four arms run
the REAL `Kazi.Runtime.run` loop over ONE tiny self-contained fixture (a
`custom_script` predicate: `solution.py` must print the sum of the first 10 primes
= 129; a stub prints `0` and fails at t0), driving a cheap model (Haiku 4.5)
through a capture shim that tees each inner `claude --output-format json` envelope
for its real `total_cost_usd`/`usage`:

  * **t0-on** — tier 0 (evidence only, no orientation), surface minimal.
  * **t1-on** — tier 1 (+ cached orientation, the DEFAULT), surface minimal.
  * **t1-off** — tier 1, surface **ambient** (the pre-T36.2 full tool/MCP set).
  * **t2-on** — tier 2 (+ live graph MCP), surface minimal.

**Verdict.** Two clear, opposite results:

1. **Tool-surface ON (the `:minimal` T36.2 default) is a real, mechanism-grounded
   token win — NOT net-neutral.** Surface-off (ambient) cost **~2× the tokens and
   ~40% more $** than surface-on for the same one-dispatch convergence: the saving
   is entirely in the CACHED input the harness re-sends every turn (t1-on 90,984
   cached vs t1-off 182,279 cached; output 1,406 vs 1,245 and turns 8 vs 7 are
   ~equal — so the delta is the loaded tool/MCP schema set, not agent flailing).
   **KEEP surface `:minimal` (on) as the default.**
2. **The context-tier knob is net-neutral on a within-reach fixture.** Tier 0/1/2
   all converged in ONE dispatch at $0.0489–$0.0545 — inside the run-to-run noise
   floor. On a tiny scratch workspace the tier-1 orientation pack was only ~49
   tokens and the tier-2 graph MCP server was empty (no graph DB), so the tier had
   nothing to bite on. This reproduces the T19.7 finding (a self-verifying inner
   harness converges most within-reach slices in one dispatch on EVERY tier).
   **KEEP tier 1 as the default** (evidence + the cached orientation pack — the
   safe knee); the tier ladder earns its keep only on a fixture beyond the cheap
   tier's reach, which is exactly what the T36.4 escalate-on-non-progress ladder
   (gated, not reflexive) is for.

**The tier × surface table** (generated by the new `mix kazi.bench --tier-surface`
wiring from the recorded live run — `$`/tokens from each captured `claude`
envelope's `total_cost_usd`/`usage`; convergence/correctness from each arm's
terminal result; the predicate IS the correctness oracle, so a cheaper-but-WRONG
arm would show `Correct = no`):

| Arm | Tier | Surface | Dispatches | Tokens | Cost (USD) | Cost/conv-pred | Converged | Correct | Stuck |
|---|---|---|---|---|---|---|---|---|---|
| t0-on | 0 | on | 1 | 90811 | 0.0530 | 0.0530 | yes | yes | no |
| t1-on | 1 | on | 1 | 92424 | 0.0545 | 0.0545 | yes | yes | no |
| t1-off | 1 | off | 1 | 183559 | 0.0768 | 0.0768 | yes | yes | no |
| t2-on | 2 | on | 1 | 71983 | 0.0489 | 0.0489 | yes | yes | no |

(Cost = the summed `total_cost_usd` of the arm's captured envelope; there is one
converged predicate, so cost/conv-pred = cost. All four arms converged and were
correct — the check script independently verifies the output is 129.)

**Default recommendation set FROM this data.** Surface `:minimal` (on) stays the
default — a measured ~2× cached-token / ~40% cost win with no convergence penalty.
Tier `1` stays the default — net-neutral on a within-reach slice, so there is no
data-driven reason to move it; escalation (T36.4) handles the beyond-reach case.
No default was changed by this run; both shipped defaults are now data-backed.

**Run scale + ACTUAL cost incurred.** A minimal, representative LIVE run — NOT a
full tier-0..4 × surface-on/off matrix: ONE fixture, 4 arms (tiers 0/1/2 at
surface-on + tier-1 at surface-off — the two cleanly-variable axes), one dispatch
each, plus a feasibility probe and one de-risking smoke run. **Total real spend ≈
$0.42** (probe $0.028; a first smoke run that burned $0.104 fighting a missing
permission mode before I added `permission_mode: :bypassPermissions`; a clean
smoke $0.052; the 4 measured arms $0.0530 + $0.0545 + $0.0768 + $0.0489 = $0.233).
Far under the authorized ceiling. Every measured `$` traces to a captured envelope.

**Honest caveats (the limits of this run):**

1. **The ambient ABSOLUTE number depends on the operator's local config.** The
   surface-off arm loads the full configured tool/MCP schema set, so t1-off's
   182k-token figure scales with how many MCP servers the operator has configured.
   The robust, mechanism-grounded finding is the DIRECTION and roughly-2× MAGNITUDE
   (minimal ≪ ambient because ambient re-sends every irrelevant schema each turn),
   not the exact multiple — which only gets larger with a richer ambient.
2. **Tiers 3–4 were NOT measured live.** Their content sources (retrieval snippets,
   compact repo snapshot) are scaffolded but not yet wired (T36.3 left them as
   named seams), so a live tier-3/4 arm would assemble the same context as tier 2
   on this fixture — nothing new to measure. Marked out of scope here, honestly,
   rather than run as a fake distinct arm.
3. **A within-reach fixture cannot stress the tier ladder.** As in T19.7, every
   tier converged in one dispatch, so the tier knob's value (and the T36.4
   escalation) is invisible here by construction. Demonstrating a live tier CLIMB
   needs a slice genuinely beyond the cheap tier's reach on a real codebase — the
   documented next step; manufacturing a failure cheaply was not attempted (it
   would be gamed).

**Harness wiring added (T36.5).** `Kazi.Bench.tier_surface_arm/3` +
`tier_surface_report/1` + `render_tier_surface_table/1` (pure: fold each arm's
captured envelopes for real `$`/tokens + its terminal result for
convergence/correctness/stuck + the cost/converged-predicate ratio, parsing
tier/surface from the `t<tier>-<on|off>` label) and a
`mix kazi.bench --tier-surface <dir>` mode that aggregates the recorded arms (each
arm = `<arm>.result.json` + captured `<arm>.NNN.json` envelopes), sorted by
(tier, surface). Plus `Kazi.Harness.DispatchSurface`: a `:dispatch_surface,
:ambient` OFF switch (the surface-off arm + an operator escape hatch) and
`surface_mode/1` to label it. Bench + dispatch-surface unit suites green;
`mix format` clean; hermetic fixtures under `test/fixtures/bench/tier_surface/`.

**Reproduce.** Drive the four arms with `Kazi.Runtime.run(goal, harness: :claude,
model: "claude-haiku-4-5", adapter_opts: [context_tier: <0|1|2>, dispatch_surface:
<:minimal|:ambient>, permission_mode: :bypassPermissions, command: <capture-shim>])`
over a tiny `custom_script` fixture in a scratch workspace, capturing each inner
`claude --output-format json` envelope (a thin `claude` shim on `PATH` that tees
the envelope), then `mix kazi.bench --tier-surface <dir>`.

## 2026-06-25 — in-family tiering cost benchmark (T19.7): static-cheap wins; escalation collapses to the cheap tier (best case)

The LIVE in-family cost proof T34.7 left open (ADR-0033/0035; verifies UC-043,
UC-045, UC-033). Three tiering arms run over ONE tiny self-contained fixture (a
`custom_script` predicate: `solution.py` must print the sum of the first 10 primes
= 129; a stub fails at t0), driving the real `kazi apply --harness claude --model
<id>` path, with each inner `claude --output-format json` envelope captured for its
real `total_cost_usd`/`usage`:

  * **A — vanilla-frontier**: a frontier model (Opus 4.8) grinds the whole goal.
  * **B — static-cheap**: a cheap Claude model (Haiku 4.5) grinds predicates a
    frontier model authored once (ADR-0033 static tiering).
  * **C — escalating**: start cheapest (Haiku), climb Haiku→Sonnet→Opus ONLY on a
    kazi-reported non-converged/stuck signal (ADR-0035; the ladder is an
    orchestrator-side state machine, not kazi-core).

**Verdict.** In-family tiering is real and cheaper, with a sharp caveat: on a
slice the cheap tier can converge, **static-cheap is ~3× cheaper than
vanilla-frontier for the same correct result, and the escalating arm collapses to
the cheap tier — never paying frontier rates** (the best case ADR-0035 predicts).
But escalation is NOT free insurance: when it has to climb the full ladder it
costs MORE than just starting on the frontier (the net-negative risk ADR-0035
flags, now measured). Escalation pays off only when the cheap tier's failure is
cheap relative to the frontier work it saves — so the stuck-threshold must be
tight, and the default should be the cheapest *capable* tier, not reflexive
climbing.

**Run scale + ACTUAL cost incurred.** A minimal, representative LIVE run — NOT
exhaustive: ONE fixture, the canonical 3 arms + one constructed worst-case, plus 3
cheap feasibility probes. **Total real spend ≈ $0.53** (4 captured live-arm
envelopes = $0.4099; 3 probes ≈ $0.12, one de-risk Haiku run's cost uncaptured
but ~$0.05 by comparison). Far under the authorized ceiling — the fixture is
deliberately tiny so each dispatch is a small edit. Every $ below traces to a
captured envelope.

**The tiering table** (generated by the new `mix kazi.bench --tiering` wiring from
the recorded run — `$`/tokens from each captured `claude` envelope's
`total_cost_usd`/`usage`; convergence + correctness from each arm's
`kazi apply --json`):

| Arm | Model(s) | Dispatches | Tokens | Cost (USD) | Converged | Correct |
|---|---|---|---|---|---|---|
| vanilla-frontier | claude-opus-4-8 | 1 | 83720 | 0.1619 | yes | yes |
| static-cheap | claude-haiku-4-5 | 1 | 91770 | 0.0536 | yes | yes |
| escalating (observed) | claude-haiku-4-5 | 1 | 90557 | 0.0527 | yes | yes |
| escalating-worstcase* | claude-haiku-4-5 → claude-sonnet-4-6 → claude-opus-4-8 | 3 | 264642 | 0.3572 | yes | yes |

\* *constructed* from the real per-model envelopes (Haiku $0.0527 + Sonnet $0.1417
+ Opus $0.1619): what the escalating arm WOULD cost if a slice forced it up the
full ladder. The live escalating arm never climbed — Haiku converged on rung 1, so
it cost the cheap-tier rate. The worst-case row makes the "always-escalates-to-
frontier" outcome visible per the acceptance: at **$0.3572 it is 2.2× MORE than
vanilla-frontier's $0.1619.**

**Per-dispatch single-model cost on this slice:** Haiku **$0.0527** · Sonnet
**$0.1417** · Opus **$0.1619**. Haiku is ~3× cheaper than Opus. Sonnet ≈ Opus here
because the per-dispatch FIXED overhead — Claude Code re-injects a ~70k-token
cached system prompt every dispatch (cache-read + cache-creation), priced per the
model's own cached/write rate — dominates a tiny slice's tokens. The tier gap
widens on larger slices with more generated output; on trivial slices it compresses.

**Convergence + correctness.** All three live arms converged and were **correct**:
the `custom_script` predicate IS the machine-checkable correctness oracle (the
check script independently verifies the output is 129), so a cheaper-but-WRONG
result would show `Correct = no`, never a false done. The new wiring's unit suite
pins exactly that with a `static-fails` arm (converged=no, correct=no) and a
converged-but-failing-predicate case (correct=no).

**Honest findings (the caveats that matter more than the headline):**

1. **A self-verifying agentic inner harness converges most within-reach slices in
   ONE dispatch — on EVERY tier.** With bash + the check script as an oracle (the
   workspace grants edit/bash), even Haiku writes, runs, and self-corrects inside a
   single `claude -p` dispatch, so kazi never observes "stuck" and escalation never
   fires. This is why the escalating arm collapsed to Haiku. Stressing a live ladder
   CLIMB needs a slice genuinely beyond the cheap tier's reach (a documented next
   step); manufacturing a failure cheaply was not attempted (it would be gamed). The
   ladder's climb logic is instead pinned by the escalating-worstcase row (real
   per-model envelopes) + the `Kazi.Context.Escalation` unit tests.
2. **kazi's `--json` `economy` omitted `cost_usd` and reported `tokens: 0` on these
   runs.** `Kazi.Harness.Profiles.Claude.parse/1` DOES parse `total_cost_usd`, but
   the run-aggregate economy did not surface it — so the benchmark sourced real `$`
   from the inner `claude` envelope directly via a capture shim (the bench's
   documented design), not from kazi's economy. Wiring the harness's
   `total_cost_usd` through to kazi's economy envelope is a worthwhile follow-up
   (it would let `--kpis` carry real cost without a shim).
3. **Local-Qwen privacy arm (secondary):** the BYOM/privacy comparison
   (`--harness opencode --model local/qwen3.6`, ADR-0033's privacy add-on, demoted
   below the in-family default) is noted as the secondary axis only — **NOT run**
   here (no local model). It trades $ for on-prem privacy, not for raw cost.

**Harness wiring added (T19.7).** `Kazi.Bench.tiering_arm/3` +
`tiering_report/1` + `render_tiering_table/1` (pure: fold each arm's captured
envelopes + terminal result into the `$`/tokens/dispatches/convergence/correctness
row) and a `mix kazi.bench --tiering <dir>` mode that aggregates the recorded
arms (each arm = `<arm>.result.json` + captured `<arm>.NNN.json` envelopes) into
the table above. 22 bench tests green (`mix test test/kazi/bench_test.exs
test/mix/tasks/kazi_bench_test.exs`); `mix format` clean; fixtures under
`test/fixtures/bench/tiering/`.

**Reproduce.** Drive the three arms with `kazi apply --harness claude --model
<claude-opus-4-8|claude-haiku-4-5|claude-sonnet-4-6>` over a tiny `custom_script`
fixture in a scratch workspace, capturing each inner `claude --output-format json`
envelope (a thin `claude` shim on `PATH` that tees the envelope), then
`mix kazi.bench --tiering <dir>`.

## 2026-06-25 — economy benchmark A/B/C (T34.7): KEEP the stable-prefix wiring

The multi-iteration economy benchmark the single-dispatch T15.9 run could not
settle (devlog 2026-06-24 "token benchmark (T15.9)"), now run through the T19.4
harness (`mix kazi.bench`) and the T34.6 economy KPIs (`--kpis`), ADR-0046. The
open question this closes: across iterations, does the T19.1 orientation prefix +
T19.2 stable-head discipline pay for itself, or should that wiring be reverted?

**Verdict: KEEP.** The stable-prefix wiring stays. It is grounded in real
evidence + the shipped mechanism; the one quantity still unmeasured live is the
*magnitude* of the multi-iteration win (see "Honesty" below).

**Run scale + cost actually incurred.** ZERO live Claude dispatches, ZERO API
spend. I ran only the harness's two deterministic OFFLINE replay paths
(`--captures`, `--kpis`) over the recorded fixtures, and the bench + economy unit
suite (46 tests, green). I did NOT hand-orchestrate a live 3-arm convergence — see
"What a full live run still needs". The budget guardrail (T34.7 brief) explicitly
permits an honest, mechanism-grounded verdict over silently burning budget.

**The A/B/C tables (`mix kazi.bench`).** Reproduced end-to-end from the recorded
fixtures under `test/fixtures/bench/`:

Token + cost + iteration table (`--captures test/fixtures/bench/captures`):

| Arm | Iters | Input | Output | Cache-create | Cache-read | Total | Cost (USD) |
|-----|-------|-------|--------|--------------|------------|-------|------------|
| A — vanilla `claude -p`        | 1 | 12972 | 1116 | 24236  | 288183 | 326507 | 0.4790 |
| B — kazi, NO prefix (pre-T19.1) | 3 | 12900 | 1200 | 287500 | 0      | 301600 | 0.4800 |
| C — kazi, WITH prefix (default) | 3 | 6600  | 1170 | 96000  | 191000 | 294770 | 0.2380 |

Economy-KPI breakdown (`--kpis test/fixtures/bench/kpi_runs`, T34.6/ADR-0046):

| Tier (arm) | Runs | Stuck | Conv | Cost/conv-pred | Wall/conv-pred (s) | Iters-to-conv | Fresh-input-avoided | Rediscovery-avoided |
|------------|------|-------|------|----------------|--------------------|---------------|---------------------|---------------------|
| B | 1 | 0.00 | 1.00 | 0.090000 | 44.0 | 4.0 | 0     | 0  |
| C | 2 | 0.50 | 0.50 | 0.035000 | 30.0 | 3.0 | 70000 | 32 |

**Provenance of every cell — zero fabrication.** Arm A's row is a REAL recorded
`claude --output-format json` envelope from the live T15.9 single-dispatch run
(cost 0.4790; in 12972 / out 1116 / cache-read 288183 — identical to the T15.9
table). Arms **B and C are SYNTHETIC, illustrative fixtures** committed to exercise
the aggregation pipeline; they are NOT a fresh live measurement and must not be read
as one. The KPI fixtures are likewise synthetic (the C tier even carries a stuck run
to exercise the stuck-rate path, hence Conv 0.50). So the tables demonstrate the
**measurement pipeline is correct and ready**; they do not by themselves prove the
verdict. The verdict rests on the real evidence + mechanism below.

**Why KEEP — the real evidence + shipped mechanism.**
1. **It cannot hurt (REAL, measured).** T15.9's live single-dispatch A/B showed the
   prefix adds **~0% token overhead (+0.5%, +$0.0001)**. The orientation prefix is
   purely additive; when there is no graph/repo-map the pack is empty and the prompt
   is **byte-identical to the pre-T19.1 path** (`loop.ex:1690`). No regression risk.
2. **The baseline IS cacheable (REAL, measured).** T15.9's arm-A envelope carries
   **288,183 cache-read tokens** — the ~290k static head (system prompt + tools +
   workspace) is already server-cached with a 5-min TTL.
3. **The wiring is the precondition for reusing that cache (SHIPPED mechanism).**
   kazi drives `claude -p` as a subprocess and sets **no `cache_control`** — the
   ONLY lever it has is a deterministic **byte-stable prefix** (`loop.ex:1696`).
   T19.1/T19.2 front-load the prompt stable→volatile (orientation pack → work-item
   → digest → volatile evidence) and carry the head byte-identical across
   same-blast-radius iterations (`last_orientation_prefix`, `loop.ex:1906/1919`).
   Without this wiring, iterations 2..N re-send that ~290k head as FRESH input (cache
   miss); with it, they hit `claude -p`'s own prompt cache as cache-read. Since the
   head is the dominant cost component and is provably cacheable (point 2), keeping
   it stable is the difference between re-paying vs reusing it every iteration 2..N.
   This is exactly the structural asymmetry the synthetic fixtures encode (arm B
   cache-read 0 / cache-create 287500; arm C cache-read 191000 / fresh-input-avoided
   70000; cost/conv-pred 0.035 vs 0.090).

So the wiring demonstrably adds ~0% tax (can't hurt), is purely additive/backward
-compatible, and is the necessary precondition for the multi-iteration cache reuse
the real arm-A envelope proves is available. Reverting it would forfeit that reuse
for no measured token saving. **KEEP.**

**Honesty — what is NOT yet proven.** The *magnitude* of the multi-iteration win —
the live arm-B-vs-arm-C delta in cost/converged-predicate — has **not** been
measured against a live model. The repo's only B/C numbers are synthetic fixtures.
The verdict on the keep/revert axis is clear and defensible (KEEP); the headline
"X% cheaper across iterations" number remains UNMEASURED and must not be published
until the live run lands.

**What a full live run still needs (T19.5 path).** `mix kazi.bench`'s LIVE path is
intentionally not wired — it prints a notice and defers to a maintainer
(`kazi.bench.ex:106`). A real 3-arm multi-iteration run requires, OUT OF BAND of the
mix task: (a) a **≥3-dispatch fixture** (a goal kazi cannot converge in one shot) in
a real git repo with workspace permissions granted (not `/tmp` — opencode rejects
scratch dirs, T8.11); (b) a **tee wrapper** on `PATH` capturing each per-dispatch
`claude --output-format json` envelope (kazi persists none); (c) three runs — arm A
`claude -p`; arm B `mix kazi.apply` with `orientation_prefix: false`; arm C the
default — collecting envelopes + each run's `apply --json` `economy` object; (d)
feeding those into `--captures` / `--kpis`. Estimated footprint ~10 live dispatches
(3 arms × ≥3 iters) at ~$0.40–0.50 each ≈ **$5–15**, plus per-arm convergence loops
that can run several minutes and have hung before (T15.9 arm C hung ~6 min). That
orchestration + hang risk, not the dollar cost, is why it is a deliberate
maintainer step and was not run autonomously here.

**Bottom line.** KEEP the stable-prefix wiring. Proven ~0% single-dispatch tax +
purely-additive/backward-compatible + the real arm-A envelope proves the ~290k head
is cacheable and the wiring is the only lever to reuse it across iterations. The
multi-iteration savings *magnitude* is the single number still owed by a live T19.5
run; until then it stays unpublished. Subsumes/unblocks T19.5.

## 2026-06-25 -- Live site shipped two stale-command (vaporware) bugs that no CI gate caught

**What happened.** A `/loop /apply --pool` session shipped E25 content (T25.1/T25.5/T25.6
-> PR #454; T25.8 -> PR #459), deployed to GitHub Pages, and verified live at
https://kazi.sire.run. During live verification it found two deprecated/removed `kazi`
verbs still rendered in production:
1. The Install section of `site/src/pages/index.astro` (step 2) shows the REMOVED
   `kazi propose` -> `kazi approve` proposal flow (the current verbs are `kazi plan` /
   `kazi apply`; `propose` is a deprecated alias).
2. `proof-loop.svg` (the hero proof asset) shows `kazi run my-goal.toml` -- the removed
   `run` verb. An `.svg` is XML text, so a text grep over `site/` reaches it.

**Root cause (why it shipped unguarded).** The repo has two coherence gates, and NEITHER
covers the site's command accuracy: T9.9 (`site/scripts/check-coherence.mjs`) only diffs
a small set of canonical STRINGS between README and site; T16.4 only scans
`SKILL.md`/`AGENTS.md` against the CLI. So a stale `kazi <verb>` anywhere in `site/`
passes CI. Remediation existed in the plan only as dep-gated rewrites (T25.4/T25.10/T22.7)
and the verb-rename sweep T27.6; none had run, so the drift went live.

**Action.** Added T29.4 (a standing site command-accuracy CI guard, warn-then-block) to
close the gap, and annotated T27.6 (the ready, direct fix for bug #1) and T25.2 (owns bug
#2 via asset replacement) as confirmed-live. Lesson: a canonical-STRING coherence check is
not a command-ACCURACY check; the no-vaporware guarantee needs a verb-level scan over every
published surface (README + docs + site + rendered assets), not just the strings under test.

## 2026-06-24 -- Content-marketing research: how fast-growing OSS AI tools won stars (motivates ADR-0030 / E25)

Two sourced deep-research passes (~15 tools + the agent-native/MCP tier + HN launch
data) into what the fastest-growing OSS AI dev tools put in their README/site/docs
and how they won stars. Distilled into ADR-0030 + planned as E25. Key findings:

- **kazi's closest analogs are agent-FACING tools the user doesn't operate:**
  **Serena** ("The IDE for Your Coding Agent" / "Give your agent the tools it has
  been asking for"; testimonials authored BY the agents), **Context7** ("Up-to-date
  docs for any prompt"; invocation IS the marketing -- append "use context7"; ~55-58K
  stars, fastest in set), and **Astral's Ruff/uv** (benchmark chart as hero, a
  falsifiable "10-100x" number).
- **Content patterns correlated with star growth:** (1) a category-defining one-liner
  in line 1, in the human's noun not the protocol's; (2) lead with a VISUAL that
  proves the claim (speed tools -> benchmark chart; agent tools -> a transcript of
  the agent using it); (3) ONE recurring earned-media engine (Aider's leaderboard,
  Astral's benchmark) beats scattered effort; (4) a theatrical falsifiable number;
  (5) borrowed credibility / borrowed category; (6) two-layer proof (lean README,
  proof-heavy site); (7) friction-to-first-use = one copy-paste command/config.
- **Agent-tool positioning (kazi's hardest problem):** name the human's noun not
  "MCP server"/"controller"; "give your agent X" (benefit through the agent); lead
  with the agent's CURRENT pain then show it fixed (Context7's before/after, the
  most-copied device); show the agent USING the tool; make the invocation a
  memorable phrase.
- **Launch mechanics (HN-sourced, high confidence):** HN is the highest-leverage
  channel; title formula `<Name> - <plain capability>, <differentiator>` (Aider 432
  pts, uv 647, Tabby "self-hosted Copilot" 627, Zed open-sourcing 1576). Time to a
  wave (OpenHands rode Devin; Cursor rode Sonnet 3.5; the agent category rode MCP's
  OpenAI/Google adoption). Ship 1 release/day with "something significant" (Marsh's
  Ruff playbook). Reddit/Product Hunt returned NO falsifiable data -- unproven, not
  disproven.
- **Highest-leverage asset:** a visual that proves the core claim above the install
  command; for kazi = an asciinema/transcript of claude -> kazi -> harness with
  predicates flipping false -> true. Evidence: Astral's chart drove Ruff to 5K stars
  in <5mo; Serena's agent-voiced demo to ~25.7K; Context7's "use context7" to ~55K.
- **Honest risks:** (#1) "done" is harder to make falsifiable than "fast" -- if it
  can't be a number a skeptic reproduces in 60s, the hook misfires; the dogfood
  leaderboard is the mitigation. Category-education tax on "reconciliation
  controller" -> use a borrowed frame ("CI for coding agents"). AI tool fatigue +
  crowded harness field -> be unmistakably a different LAYER (verification), not
  another harness. Host-ecosystem dependence (Claude Code/MCP) -> keep multi-harness.
  Stars != adoption (fake-stars ~5x weaker, a liability) -> instrument downloads /
  time-to-second-PR. Maintainer attrition is the empirical #1 OSS killer.
- Full per-tool table + sources (raw READMEs + HN item IDs + the MCP-adoption and
  fake-stars papers) are in the session research; the durable distillation is
  ADR-0030.

## 2026-06-24 — E18 shipped: the four benchmark bugs fixed + clean re-verify (T18.5)

Fixed all four defects the token benchmark surfaced (2026-06-24 entry below), each
with a regression test; full suite green (1353 passed), `mix format` +
`--warnings-as-errors` clean.

- **T18.1** (stale example): `priv/examples/{deploy_target,standing_maintenance,
  grouped_taxonomy}.toml` used a whole command line in `cmd` (`"go test ./..."`),
  which `System.cmd/3` runs as one binary -> `{:cmd_unrunnable, :enoent}`. Split into
  `cmd` + `args`. New guard `examples_runnable_test` loads every
  `priv/examples/*.toml` and asserts each `:tests` predicate's `cmd` is a single
  whitespace-free token with a list `args` (L-0012).
- **T18.2** (read-model crash): `ReadModel.serialize_vector/1` stored evidence
  verbatim; an `:error` result's tuple reason + atom keys failed the Ecto `:map`
  cast so `record_iteration/1` raised and the iteration was lost. Added a recursive
  `sanitize_evidence/1` (stringify keys, keep JSON scalars, stringify atoms, inspect
  tuples/structs); idempotent on already-sanitized maps (L-0010).
- **T18.3** (duplicate-index persist): persistence is a PROJECTION of observed
  state, so re-projecting an `iteration_index` must be idempotent. The runtime now
  always upserts from `persist_iteration` (on_conflict replace, conflict_target the
  unique pair); the stuck-stop projection (reuses `iterations-1`) and budget paths
  no longer collide on `iterations_goal_ref_iteration_index_index`. The read-model
  keeps its duplicate-rejecting contract for direct callers (L-0011).
- **T18.4** (over-budget CaseClauseError): already fixed by T15.3 (`cli.ex` has the
  `:over_budget` clause). Added a regression test: an unconvergeable goal
  (`max_iterations=1`, no-op harness) exits 1 + reports `over_budget` on both human
  and `--json`, raises nothing, and logs no persistence collision.
- **T18.5** (re-verify): a real `mix kazi.run` on a broken Go fixture (healthBody
  `not-ok`, NATS-free, in-memory read-model) converged in 2 iterations -- the agent
  applied the one-line fix, the upsert (`ON CONFLICT DO UPDATE`) fired, and the run
  was CLEAN: zero `failed to persist`, zero `has already been taken`, zero `:map`
  cast errors, no raise. The exact symptoms from the benchmark are gone.

## 2026-06-24 — E13 reconciliation dogfood (T13.6): kazi's own A \ I, importer demo, external-service-is-Go reality check

Ran the E13 intended-vs-actual pipeline (ADR-0021) end to end as a USAGE
exercise — no lib changes, the E13 modules are done. Two parts ran for real, one
is an honest limitation. Reproduce with `priv/scripts/t13_6_dogfood.exs`
(`mix run priv/scripts/t13_6_dogfood.exs`).

### 1. Scanner + coverage on an Elixir target kazi CAN handle: kazi itself

`Kazi.Reconcile.SurfaceScanner.scan/2` over kazi's own `lib/` (the workspace
root) found **290 public-surface elements**: 289 `:exported_function` + 1
`:mix_task` (`mix kazi.run`). (Reflection / string-dispatch entry points are
invisible to the static scan — ADR-0021's documented approximation, `docs/lore.md`
L-0006 — so 290 is a floor, not the whole truth.)

I then ran `Kazi.Reconcile.Coverage.check/3` with a REAL, representative intended
set `I`: the self-hosted goal `priv/goals/e3-t3.4-standing-reconciler.toml` (its
two `test_runner` predicates — an acceptance test + the full-suite guard). Result:

| metric | value |
|---|---|
| status | `:fail` |
| surface `A` | 290 |
| owned | 2 |
| allowed (allow-list) | 0 |
| **unowned (`A \ I`)** | **288** |

A few example unowned (candidate dead/undocumented) elements:

- `Kazi.Actions.Deploy.execute/2` (`lib/kazi/actions/deploy.ex`)
- `Kazi.Actions.Integrate.execute/2` (`lib/kazi/actions/integrate.ex`)
- `Kazi.Adopt.adopt/2` (`lib/kazi/adopt.ex:380`)
- `Kazi.Authoring.Clarify.candidate_prompt/1` (`lib/kazi/authoring/clarify.ex`)
- `Kazi.Application.start/2` (`lib/kazi/application.ex`)

Unowned, bucketed by top-level module (top of the list): `Kazi.Loop` 45,
`Kazi.Harness` 25, `Kazi.ReadModel` 25, `Kazi.Authoring` 21,
`Kazi.Coordination` 21, `Kazi.Context` 17, `Kazi.Reconcile` 17, `Kazi.Goal` 14.

### Honest read of the result: this number is a measurement of THIS goal, not "288 dead functions"

`A \ I = 288` is real but must be read as ADR-0021 frames it: it is the surface
NOT owned by the *chosen* intended set. The standing-reconciler goal's `I` is two
generic `mix test` predicates — it intends "the suite passes", not "these 290
symbols exist". So nearly the whole surface is correctly *unowned by that goal*.
The pipeline did exactly what it should; the 288 is "surface this particular goal
does not justify", a candidate list for a human, NOT a dead-code verdict. A real
dead-code pass needs an `I` authored to OWN the live surface (an OpenAPI/gherkin
import for an HTTP project, or hand-written acceptance predicates per capability),
plus an allow-list for the legitimately un-predicated (`Application.start/2`,
internal helpers).

The matcher is also demonstrably APPROXIMATE (as documented), and the dogfood
exposed both directions of noise in the 2 "owned" matches:

- `mix kazi.run` — owned only because the predicate's `cmd: "mix"` substring-
  matches the task identifier. Coincidental, not real ownership.
- `Kazi.ReadModel.latest_iteration/1` — owned only because the token `"test"`
  (from `args: ["test"]`) is a substring of "la**test**_iteration". A textbook
  false positive: `String.contains?("latest_iteration", "test") == true`.

So even the 2 "owned" are spurious; against this goal the honest A \ I is
effectively all 290. This is the intended-vs-actual loop working AND a fair
illustration of why ADR-0021 mandates "warn, don't auto-delete" + an allow-list:
the substring matcher trades false positives (acceptable) to avoid false
negatives (trust-eroding), and a coverage `:fail` is a review queue, not a
delete list.

### 2. OpenApiImporter demonstration (the importer path works)

`Kazi.Reconcile.OpenApiImporter.import_map/2` over the committed T13.1 fixture
(`test/fixtures/reconcile/petstore.openapi.json`) produced a create-mode goal
map: **6 `http_probe` acceptance predicates across 3 groups**
(`pets`, `identity-access`, `ungrouped`) —

```
get_healthz   [ungrouped]        GET  /healthz                   -> 200
get_pets      [pets]             GET  /pets                      -> 200
post_pets     [pets]             POST /pets                      -> 201
get_pets-petid[pets]             GET  /pets/{petId}              -> 200
get_users     [identity-access]  GET  /users                     -> 200
post_users... [identity-access]  POST /users/{userId}/sessions   -> 200
```

`import_goal/2` round-trips the same input straight through `Kazi.Goal.Loader`
into a `%Kazi.Goal{mode: :create}` with 6 predicates + 3 declared groups. The
deterministic spec->intent backbone of ADR-0021 §1 works as specified: a machine
spec becomes a grouped intended set with no bespoke deserialiser.

### 3. Honest limitation: the original "dogfood an external service" target is GO, not Elixir

Plan T13.6 said "dogfood an external service via the general path". Reality
check: that service's API is a **Go** codebase (`<repo>/api`, `internal/openapi`,
zero `.ex` files), and `Kazi.Reconcile.SurfaceScanner` is **Elixir-only** (it
parses `.ex`/`.exs` with `Code.string_to_quoted/2`). It therefore CANNOT scan
that service's Go surface — so the scanner+coverage half of T13.6 was dogfooded on kazi
itself (part 1) instead, which is a legitimate Elixir target and a real result.

Concrete follow-ups to actually reconcile such a service:

- **(a) A Go surface scanner** — a sibling provider that inventories Go exported
  identifiers / HTTP route registrations, emitting the same `SurfaceElement`s the
  coverage meta-predicate already consumes. This is the unblock for `A \ I` on a
  Go service.
- **(b) Consume the service's published OpenAPI spec.** When a service publishes
  one (`<repo>/docs/openapi.yaml`, e.g. ~3.2k lines, OpenAPI 3.0.3), the importer
  accepts it in principle — BUT if it is **YAML**, and `OpenApiImporter` is
  **JSON-only** (YAML deferred behind its own dep ADR, per the module's own docs).
  So the path is: `yq -o=json docs/openapi.yaml | ...` out-of-band, then
  `import_map/2`. This yields the service's intended `I` (HTTP probes grouped by
  tag) even without a Go scanner.
- **(c) Prose importer over the service's ADRs** (`Kazi.Reconcile.ProseImporter`,
  T13.3) — a service with a large `docs/adr/` tree lets the harness-drafted,
  human-reviewed path capture intent that lives only in prose.

The **live-predicate escalation** (probing a RUNNING service to assert the imported
`http_probe`s actually pass) remains **deferred** — it needs a running instance +
test credentials, out of scope here.

### Bottom line

The E13 pipeline runs end to end and produces a real, valuable result on an
Elixir target (kazi: `A \ I = 288` against a representative goal, with the
matcher's approximation honestly visible in 2 spurious "owned" hits). The
importer's deterministic spec->intent path works (6 grouped predicates from the
petstore fixture). The "dogfood an external service" goal as literally written is
blocked on language: that service is Go, the scanner is Elixir — so it needs a Go
scanner, a YAML->JSON front-end to ingest the service's existing OpenAPI spec, or
the prose path, none of which were built here. Reported as not-yet-done for the Go
service specifically; done and verified for the Elixir half.

## 2026-06-24 — token benchmark (T15.9): kazi adds ~0% overhead vs vanilla Claude

First real A/B/C token measurement (the benchmark ADR-0010 promised; the
audit below flagged it missing). Question: does claude→kazi→claude cost more
tokens than vanilla Claude?

**Method.** Broken Go fixture (`deploy-target`, `healthBody="not-ok"` → one unit
test fails). Each arm a separate real git repo under `~/kazi-bench` (NOT `/tmp` —
opencode auto-rejects scratch dirs, T8.11), with workspace permissions granted
(`.claude/settings.local.json` accept-edits + `Bash`; `opencode.json` edit/bash
allow). Tokens captured by a shim wrapping the harness binary, teeing the
`--output-format json` envelope (kazi captures tokens internally but persists/
prints none — see bugs). Code-only goal (one `test_runner` predicate), so the
LLM cost is the agent dispatch; integrate/deploy are git/HTTP, not tokens.

**Results.**

| Arm | Harness | Outcome | Total tokens | Cost | Agent turns |
|-----|---------|---------|--------------|------|-------------|
| A — vanilla | `claude -p` (one freeform session) | converged | 326,507 | $0.4790 | 9 |
| B — kazi→Claude | `mix kazi.run` → `claude` (1 dispatch) | converged | 328,141 | $0.4791 | 9 |
| C — kazi→local Qwen | `--harness opencode --model local-ollama/qwen3.6:35b-a3b-q8_0` | did NOT converge in ~6min | — (dispatch in-flight) | $0 (local) | — |

Token split was near-identical (A: in 12,972 / out 1,116 / cache-read 288,183;
B: in 12,843 / out 1,187 / cache-read 290,090).

**Findings.**
1. **kazi imposes ~zero token overhead at the same model: +1,634 tokens (+0.5%),
   +$0.0001.** Both arms invoke the SAME `claude` agent, whose static system
   prompt + tools + workspace context dominate (~290k cache-read, identical in
   both). kazi's structured dispatch prompt (digest + failing evidence) is no
   bigger than a human's freeform ask. **The "claude→kazi→claude is inherently
   more expensive" fear is false for single-dispatch convergence.**
2. **The real token risk is MULTI-dispatch, not the wrapper.** kazi is stateless
   per iteration (ADR-0008), so an N-dispatch convergence re-pays that ~290k
   baseline N times where a vanilla session amortizes it. Mitigants: (a) the huge
   `cache_read` shows the agent's static prefix is already server-cached, and the
   5-min TTL means rapid successive dispatches still hit it; (b) the unwired
   orientation-prefix + Anthropic `cache_control` (T4.3, see audit below) would
   cut iters 2..N further. So "N× baseline" is the worst case, not the typical.
3. **Cost-tiering (arm C) is real in $ structure but gated by local-model speed.**
   kazi correctly observed the failure and dispatched opencode→the local Qwen; the 35B
   q8_0 simply didn't return within 6 min (reconfirms T8.11). When it does
   converge, the per-dispatch $ is ~0 (local compute) — that is the cheaper story,
   bottlenecked by inner-harness throughput, not kazi.

**Bottom line.** kazi is NOT more expensive than vanilla for equivalent work
(proven, N=1). Its cost win needs model-tiering (gated by local-model speed); its
correctness win (objective termination = "right the first time") is free. Earned
claim today: *"kazi adds no token tax over your existing agent."* The *"cheaper"*
headline still needs a multi-iteration benchmark on a faster local model.

**Bugs surfaced during the run (not yet filed/fixed):**
- **Stale example:** `priv/examples/deploy_target.toml` uses `cmd = "go test ./..."`
  (whole command as the executable) → `{:cmd_unrunnable, :enoent}`. `test_runner`
  wants `cmd = "go"`, `args = ["test","./..."]` (README quickstart 2 is correct).
- **Read-model crash on errored predicates:** an `:error` PredicateResult whose
  evidence holds a tuple (`reason: {:cmd_unrunnable, ...}`) fails the
  `Iteration.predicate_vector` `:map` cast — `record_iteration/1` raises, so an
  errored predicate is never persisted.
- **CLI CaseClauseError:** `Kazi.CLI.run_goal/4` (cli.ex:526) has no clause for the
  `{:ok, %{outcome: :over_budget, reason: :max_iterations, ...}}` shape and crashes
  instead of printing a clean over-budget verdict.
- **Unique-constraint warning:** `iterations_goal_ref_iteration_index_index`
  "has already been taken" on iteration 0 (double persist on a path).

## 2026-06-23 — token-efficiency audit: is claude→kazi→claude cheaper than vanilla?

Audited whether the orchestrator→kazi→implementer stack (ADR-0023) actually
beats vanilla Claude on cost, and where kazi leaks tokens today. Verified against
the live dispatch path (`lib/kazi/loop.ex:1208 dispatch_prompt/2`), not the ADR
prose.

**The honest framing.** "Cheaper" ≠ "fewer tokens". The naive setup — claude →
kazi → claude with the SAME big model on every layer, stateless per iteration
(ADR-0008) — is *more* tokens than vanilla: vanilla amortizes orientation across
one growing context, while kazi re-pays per-iteration orientation N times AND
adds the orchestrator on top. kazi wins on **cost**, not token count, via two
levers that are intrinsic, not yet proven:
1. **Model tiering (ADR-0023).** Expensive model authors predicates ONCE; a cheap
   LOCAL model (e.g. Qwen on a local GPU host via opencode/claw) does the N grind iterations; objective
   predicates keep the cheap model honest. The expensive tokens are paid once; the
   N iterations run on near-free compute.
2. **"Right the first time."** Objective termination removes the hidden cost of a
   human re-prompting an agent that *thought* it was done. That cost is real but
   uncounted in a naive token diff.

**What's already shipped well (verified):** real token/cost capture from
`claude --output-format json` (`harness/profiles/claude.ex`); code-review-graph
MCP registered + refreshed in the target `.mcp.json` before every dispatch
(`workspace.ex` — gives the inner agent ~10× cheaper structural queries per
ADR-0010 research); bounded working-set digest carried across iterations as map
memory (`loop/digest.ex`); graphify retrieval adapter present (off by default,
SHA-cached); SHA-keyed orientation-pack cache keyed on `(workspace, git_sha,
failing_set)` (`context.ex:165`).

**Where kazi leaks tokens TODAY (gaps found):**
1. **Orientation pack is delivered as a file, not a cached prompt prefix.** The
   live loop's `dispatch_prompt/2` builds digest + `inspect(evidence)` + optional
   retrieval, and writes the pack to `.kazi/context.md`. The inner agent must READ
   that file (tool calls + input tokens, no cache discount) instead of receiving
   it as a stable, prompt-cacheable prefix. The prefix-injection path
   (`Harness.Prompt.build_prompt/3`, T4.3 — marked done, tested) EXISTS but is NOT
   called by the loop. Wiring it + Anthropic `cache_control` on the stable prefix
   is the single highest-leverage fix and the code is already written — realizes
   the 50–90% input savings ADR-0010 cites. **Landmine: T4.3 is "done" but unwired
   on the live path.**
2. **No Anthropic prompt caching (`cache_control`) anywhere.** Even the workspace
   file approach forfeits the cache discount on the stable goal/orientation prefix.
3. **Evidence rendered via raw `inspect/1`** in `dispatch_prompt/2`, bypassing
   `Prompt.truncate_evidence/2` (T4.8) — large evidence maps go in untruncated on
   the live path.
4. **caller-drafts mode absent (T15.2 open).** If `propose` spawns its own model to
   draft predicates while the orchestrator already reasoned about the idea, that is
   the redundant expensive call ADR-0023 §4 warns about. T15.2 caller-drafts
   removes it; until then the agent-drivable path double-pays authoring.
5. **No benchmark exists.** The "cheaper" claim is UNMEASURED — there are zero
   token A/B numbers in this repo. ADR-0010 promised "the first self-hosted run
   becomes the benchmark"; T15.9 (live claude→kazi→claw/Qwen dogfood) is the slot
   and is still open. Until run, "cheaper" must NOT appear on the README/site.

**Prioritized levers (brainstorm, not yet decided):**
- **P0 — Run the benchmark (T15.9).** Same broken fixture converged three ways:
  (a) vanilla Claude, (b) claude→kazi→Opus, (c) Opus-authors→kazi→local-Qwen.
  Record input/output/cache tokens, $, iterations, and correctness. This turns
  "we think it's cheaper" into the headline marketing line — or exposes the leaks.
- **P0 — Wire the orientation prefix + prompt caching** (realize T4.3 on the live
  loop; add `cache_control`). Highest token-per-hour win; code largely exists.
- **P1 — Ship caller-drafts (T15.2)** to kill the redundant authoring call.
- **P1 — Feed more blast-radius from the graph INTO the prompt** (impact radius /
  detect-changes symbols) so the cheap agent never greps to orient.
- **P2 — Auto-enable graphify retrieval above a repo-size threshold** (cache built);
  differential evidence (send only the delta vs last iteration); predicate-level
  memoization so expensive live/browser predicates don't re-run when their blast
  radius is unchanged.

**Bottom line:** the architecture is DESIGNED to be cheaper and the hard parts
(graph integration, token capture, caching infra) are built — but the two levers
that prove it (prompt-cache prefix, caller-drafts) are unwired and the benchmark
is unrun. "Cheaper" is the right north star; it is not yet earned in numbers.

## 2026-06-23 — harness CLI contracts researched (motivates E14 / ADR-0022)

Researched the CLI contracts of three coding harnesses to onboard as profiles
(ADR-0016 makes a harness data, not a module). The load-bearing criterion for kazi:
it drives a harness as a NON-INTERACTIVE SUBPROCESS (no TTY) and parses stdout.

- **Codex** — `codex exec "<prompt>" --json [--model <m>]` (or `codex e`) emits a
  newline-delimited JSON (JSONL) event stream (`thread.started`, `turn.completed`,
  `item.*`, `error`); `--output-schema` for a structured final; auth `OPENAI_API_KEY`
  / `codex login`. FULLY conformant — the parser mirrors the opencode NDJSON path.
  Priority addition. (developers.openai.com/codex/exec; openai/codex docs/exec.md)
- **Antigravity** (`agy` / `antigravity`) — non-interactive via `--prompt` / `-p` /
  `--prompt-file`; structured via `--output json`; `--yes` auto-approves; auth
  `GEMINI_API_KEY` / `ANTIGRAVITY_API_KEY`. LANDMINE: `agy -p` SILENTLY DROPS stdout
  under a non-TTY (pipe/subprocess/redirect) — issue google-antigravity/
  antigravity-cli#76 — exactly kazi's mode. Workaround: `--prompt-file` +
  `--output json` written to a file we read back; may need version pinning.
- **claw-code** — `claw prompt "<text>"`, env API keys (ANTHROPIC_API_KEY/
  OPENAI_API_KEY), NO documented JSON output, no model flag; the repo calls itself
  "an agent-managed museum exhibit rather than a production tool." Fails the
  structured-output bar → best-effort/demo-grade profile only (raw-stdout parse, no
  cost extraction). (github.com/ultraworkers/claw-code)

Decision recorded in ADR-0022 (conformance contract + onboarding recipe + tiered
support); built as E14. The Antigravity non-TTY landmine should also go to
docs/lore.md when T14.3 lands.

## 2026-06-23 — external-service dogfood: capability-manifest adjudication (motivates E12)

Dogfooded kazi's reconciliation thesis against an external service's
`docs/capabilities.json` (a `<service>-capability-manifest/v1`): 317 capabilities
across 9 pillars, each carrying machine-checkable evidence (`file:line`). One-off
code-level adjudication (no running service) -- does each capability's CLAIMED
evidence still exist?

- **Claimed (manifest):** WIRED 205, BACKEND_ONLY 55, FLAG_GATED 48, REMOVED 6,
  PLANNED 1.
- **kazi-verified (evidence exists now):** 307 built, 6 partial, 3 drift, 1
  no-evidence. The manifest is largely HONEST at the file-existence level.
- **Real production-readiness gaps are not "is the code there" (it mostly is)** but
  48 FLAG_GATED (not GA), 55 BACKEND_ONLY (no UI), and the manifest's own 178
  `with_drift` -- contract/behavior drift a file-existence check CANNOT see.
- Specific finds: one capability's evidence pointed at a transient
  `.claude/worktrees/...` path (never merged to main, or manifest built against a
  worktree); one capability's referenced source file was gone; several duplicate
  capability rows.

Lessons baked into ADR-0020 / E12: (1) the natural hierarchy is pillar -> domain ->
capability and the manifest already declares pillars as a closed list -> grouping
must reference a DECLARED taxonomy by id, not free text; (2) per-pillar budgets fall
out of per-group budgets + existing partitioning (no sub-goals needed); (3) the
honest next step to answer "production ready" is LIVE predicates against a running
service (needs an instance + test creds) -- code-existence != "it works". Output: an
Obsidian vault at `<repo>/tmp/state-vault/` (gitignored scratch).

## 2026-06-23 — E11 interactive `propose`: clarify phase verified live (T11.9)

Built the interactive clarify phase for `kazi propose` (E11, UC-029, ADR-0019):
a deterministic gap-detection FLOOR (`Kazi.Authoring.Clarify.gaps/2`) merged with
harness-drafted candidate questions on the existing stub seam, asked before the
draft, with answers folded into the draft prompt; an inline rationale on the goal
metadata (`--adr` also writes an ADR-lite doc); a refine loop via the existing
upsert. Suite 855 -> 899 (+44 tests).

LIVE VERIFICATION (real app, real SQLite read-model):

- **Strict, non-interactive, harness-free** — `propose "add a widgets feature"
  --strict` piped (no TTY): exit 1, `error: idea is underspecified (missing:
  live-target, scope); answer the clarify questions interactively or add detail`.
  The gap floor + `--strict` short-circuit fire BEFORE the harness.
- **Interactive clarify (forced via the `tty:` inject seam, answers over stdin)**
  — the real `terminal_ask` rendered the live-target question (3 numbered options,
  recommended starred `*`), read `2` (Production logs) from stdin, then the scope
  question (Enter = default), then the refine prompt (Enter = accept). The drafted
  predicate came back `live (prod_log)` — i.e. the chosen answer FOLDED into the
  draft (render -> IO.gets -> resolve_answer -> fold_answers -> draft), and the
  rationale printed. Proposal persisted (`prop-add-a-widgets-feature-...`).

CAVEAT (honest): the `:io.rows()` TTY AUTODETECT (`tty?/0`, the one line that
decides whether to enter the interactive path) could not be exercised in this dev
env — `mix run` runs the BEAM in noshell mode so `:io.rows()` returns
`{:error,:enotsup}`, the escript cannot bundle the SQLite NIF (so authoring has no
read-model there), and the Burrito binary cannot build on this macOS-26 host
(R-E6-1). In a real terminal launching the binary, `:io.rows()` returns `{:ok,_}`
and the verified flow runs. The rendering + choice-resolution it gates are pure
and fully unit-tested (`Clarify.render_question/1`, `Clarify.resolve_answer/2`);
the real claude harness, driven live, produced non-strict-JSON on the DRAFT call
(`proposal is not valid JSON`) — a PRE-EXISTING one-shot-parser limitation, not
E11; the clarify wiring around it ran correctly.

## 2026-06-22 — brew distribution lifecycle proven end to end (v0.1.0 -> v0.1.1)

The full release-to-upgrade chain was exercised against the live tap (E6,
ADR-0014/0017): bump `mix.exs` + the release-please manifest -> push `vX.Y.Z` ->
`release.yml` builds the three native-arch Burrito binaries (macOS arm64, Linux
x86_64, Linux arm64), SMOKE-TESTS each (`kazi_<target> --help` on its own arch)
before publishing, uploads them + `.sha256` -> regenerate `Formula/kazi.rb` ->
`brew upgrade kazi-org/tap/kazi`. Verified live: `brew upgrade` moved 0.1.0 ->
0.1.1 and the upgraded binary reports `kazi 0.1.1` (the new `kazi --version`
flag added this session). Shipping platforms: 3; only Intel macOS deferred
(GitHub macos-13 runner scarcity). The auto-release pipeline (release-please ->
build -> tap auto-bump) is wired but gated on the operator enabling
Actions-create-PRs + a `HOMEBREW_TAP_TOKEN` secret; until then releases are this
manual bump+tag. See lore L-0005 for the `mix release --overwrite` cache gotcha.

## 2026-06-22 — T8.11 heterogeneous dogfood: wiring proven, local 35B too slow to converge

**Setup.** The capstone E8 exercise: Claude (the planner) authored a tiny broken Go
fixture goal (`Add` used subtraction; `go test ./...` fails), and kazi drove
`opencode --model local-ollama/qwen3.6:35b-a3b-q8_0` (the implementer) to converge it.
The T8.9 finding was addressed first: a project-local `opencode.json` in the
workspace granting `permission.edit/bash` = `allow`, in a REAL git repo (not a
`/tmp` scratch), so opencode would no longer auto-reject edits.

**What was PROVEN (the heterogeneous loop works end to end).** kazi observed the
objective failure (`go test` exit 1, recorded the FAIL output), persisted iteration
0 to the SQLite read-model, and dispatched opencode->the local GPU host. Objective termination
held throughout: kazi could not and did not declare success while the predicate
failed. The plan/implement split (strong model authors the predicate set, cheap
local model drives the loop, predicates keep it honest) is demonstrated.

**What did NOT happen (the honest result).** opencode ran for ~40 minutes on
iteration 1 against the 35B-a3b-q8_0 and never produced an edit to `add.go`, so the
goal did not converge in a usable window. The bottleneck is the LOCAL MODEL's
agentic throughput, not kazi: opencode's loop makes several model calls per turn
(survey the repo, reason, propose the edit), each very slow on the q8_0 35B, and the
permission fix meant the blocker this time was purely speed (no auto-reject). The run
was capped manually.

**Takeaway / landmine.** "Claude plans, local model implements" is mechanically
sound and kazi's correctness guarantee holds regardless of implementer quality. Its
PRACTICALITY is gated by local-model speed: a local ~35B-q8_0 via opencode is too slow
for an interactive convergence loop. To make this dogfood converge, use a faster
local model (smaller/lower-quant, or a faster server), or accept long wall-clock for
batch-style runs. The throwaway workspace is `~/kazi-dogfood` (a single-predicate
`go test` goal); rerun `kazi run ~/kazi-dogfood/dogfood.goal.toml --harness opencode
--model <faster-model> --workspace ~/kazi-dogfood` to retry.

## 2026-06-22 — E8 generic multi-harness support shipped; opencode->local-model live smoke skips

**What shipped (ADR-0016).** The single `Kazi.Harness.ClaudeAdapter` was generalized
into config-driven harness **profiles**: `Kazi.Harness.Profile` (a `command` + a pure
argv renderer + a pure stdout parser + supported opts), a `Kazi.Harness.Registry`
(`:claude`, `:opencode`), one generic `Kazi.Harness.CliAdapter`, and a
`Kazi.Harness.resolve/1` seam (CLI `--harness`/`--model` > goal-file `[harness]`
table > `config :kazi, :harness` > default `:claude`). `Kazi.Runtime`, `Kazi.CLI`,
`Kazi.Authoring`, and `Kazi.Adopt.enrich` all route through it; the Claude path is
pinned byte-for-byte by a golden test (CliAdapter+claude == the old adapter). Adding a
harness is now profile DATA, not a new module. Suite 755 → 853.

**opencode specifics.** opencode's non-interactive surface is
`opencode run "<msg>" --model <provider/model> --format json`, where `--format json`
emits an **NDJSON event stream** (not Claude's single envelope) — which is exactly
why a profile carries a parser strategy, not just an argv template.

**Live opencode->local-model smoke: ATTEMPTED, did not converge, SKIPS honestly.** With
opencode v1.17.9 wired to a locally-hosted Qwen3.6 35B-A3B, a `kazi run --harness
opencode` against a fixture goal returned `{:error, :await_timeout}` after ~480s. The
endpoint and model were reachable (~100s/turn via a direct probe); the non-convergence
is environmental, not a kazi defect, with two causes:
1. the local 35B model is slow (~100s/turn), so a multi-iteration converge blows
   the loop's await window;
2. **opencode auto-rejects tool calls when run in an external/scratch workspace** —
   `external_directory; auto-rejecting` — so the agent never edits and the predicate
   never flips. The target workspace must be one opencode's permission policy treats
   as in-scope (not a bare `/tmp` dir).
The live test is tagged `:opencode_live` and EXCLUDED by default (it never gates CI);
run it manually with `mix test --only opencode_live` against a responsive endpoint and
a permitted workspace. No convergence was claimed.

## 2026-06-22 — WITHDRAWN: the E7 registry adapter (the entry below is now history)

The capability-registry adapter described in the next entry was **removed** before
the open-source release. `capabilities.json` was a bespoke artifact of one internal
product; it did not generalize, and shipping a `--registry` flag whose input format
nothing public produces is a liability for a v1 OSS tool. Deleted
`Kazi.Adopt.Registry`, the `kazi init --registry` CLI mode + tests, the
`capabilities.json` fixture, and the goal-set writer path. Kept the general pieces:
stack-detection `kazi init <repo-dir>` (ADR-0013) and the goal-file writer
`Kazi.Adopt.to_toml/1`. ADR-0015 rewritten to record the withdrawal and to point at
the generalizable replacement — a future importer for a STANDARD spec (OpenAPI
paths → `http_probe`; gherkin scenarios → acceptance predicates) under its own ADR
when there is demand (UC-025, deferred). Suite 785 → 755. The entry below remains as
a record of what was built and why the cardinality decision was made.

## 2026-06-22 — E7: registry adapter + goal-set (`kazi init --registry`), ADR-0015

**What shipped.** `kazi init` grew a second deterministic source: a capability
registry (`capabilities.json`) -> a goal SET, one goal-file per capability
(ADR-0015). Delivered in PR #75 alongside the two prerequisites that did not yet
exist on main — the goal-file writer `Kazi.Adopt.to_toml/1` (T5.3) and the `kazi
init` CLI verb (T5.5). New modules: `Kazi.Adopt.Writer` (deterministic hand-rolled
TOML renderer + commented `http_probe` live-predicate scaffold; no TOML-encoder
dep) and `Kazi.Adopt.Registry` (`parse/2`, `to_goal_set/2`). JSON decode via the
existing `jason` dep. Suite 741 -> 785.

**The cardinality decision (ADR-0015).** One goal-file PER capability, not one
goal carrying a predicate matrix. A goal is the unit of convergence/budget/status;
a capability is the unit of "what the product does" and the status we want
computed. A predicate matrix would couple N capabilities into one convergence unit
(one failure => whole goal stuck; shared budget; per-capability status lost). The
goal set is what makes status loop-computed per capability — the point of the
feature.

**Boundaries enforced mechanically.** Prose `.md` is rejected before reading
("generated views, not registry inputs" — bakes JSON-is-truth into the tool).
Source-inferred bindings stay behind `--enrich` (off by default), filling only
gaps, never overriding a declared binding. Live predicates are commented TODO
scaffolds, never guessed.

**Independent verification (not the subagent's word).** Ran the fixture
`capabilities.json` (3 capabilities) through `Registry.parse` -> `to_goal_set` ->
`Kazi.Goal.Loader.from_map` myself: all 3 goals load; a multi-binding capability
yields multiple `test_runner` predicates; prose `.md` rejected with a clear
message. The convergence test (`adopt_registry_convergence_test.exs`) drives a
registry-derived goal through the REAL `Kazi.Runtime` with the same stub seams
`Kazi.RuntimeTest` uses and reaches `:converged` — proving a registry-derived goal
is runnable, not merely loadable.

**Plan note.** E7 listed T5.3/T5.5 as prereqs and also (accidentally) duplicated
their WBS lines; reconciled to single entries under E5, marked done. T6.2 (Burrito
wrap, PR #74) merged its config/wiring but is left UNCHECKED: the host binary
could not be linked locally (Zig 0.15.2 vs macOS-26 SDK); it completes on the T6.3
CI matrix (macOS-15/Ubuntu runners), not this machine.

## 2026-06-21 — Slice-2 creation dogfood (T2.5): kazi BUILDS a small real feature from failing acceptance criteria to green-and-live

**What was exercised.** The Slice-2 creation acceptance dogfood (UC-010, D2) —
the creation analog of the Slice-0 full-loop dogfood (T0.11/T0.12) and the
Slice-1 regression dogfood (T1.8). Where Slice 1 proves kazi catches a BAD fix,
this proves kazi makes a GOOD one: it does not just REPAIR regressed behavior, it
CREATES behavior that did not exist before. Driven end-to-end through the REAL
`Kazi.Runtime`/`Kazi.Loop` with the REAL providers (`Kazi.Providers.TestRunner`
over a real temp workspace; `Kazi.Providers.HttpProbe` over a REAL local server),
the REAL `Kazi.Harness.ClaudeAdapter` (pointed at a real local "build" binary via
its `:command` seam), the REAL `Kazi.Actions.Integrate` (a real local
rebase-merge into a bare `origin`, no GitHub) and `Kazi.Actions.Deploy` (a stub
emulating `gcloud run deploy`, no gcloud), and real SQLite read-model
persistence. Test: `test/kazi/slice2_dogfood_test.exs`. Hermetic: own Sandbox
connection, a real harness binary, a real temp git repo, a real local HTTP
server — no Go, no external network, no GitHub, no GCP, no real browser.

**The feature spec (as failing acceptance predicates).** A tiny real feature —
*GET /greeting returns 200 with a body containing `hello, kazi`* — authored as a
create-mode goal (`mode: :create`) whose three acceptance criteria are all
designed to FAIL at t0:

- `feature_built` (`tests`, acceptance): the feature source exists
  (`grep -q '^built$' greeting.feature`). RED at t0 (marker `absent`). This CODE
  criterion is what carries the loop past dispatch into integrate/deploy.
- `greeting_endpoint` (`http_probe`, acceptance): `GET /greeting` returns 200. A
  REAL request against a running stdlib `:inets`/`:httpd` server. RED at t0 — the
  route does not exist yet, so the server genuinely **404s** (the
  `create_feature.toml` "no such route yet" shape).
- `greeting_body` (`http_probe`, acceptance): `GET /greeting` body contains
  `hello, kazi`. The precise behavior kazi must CREATE. RED at t0 (no endpoint).

The "live" check is a REAL http_probe request against an actually-running local
server whose response the deploy step rewrites — "live" here means a genuinely
running service the probe hits over `127.0.0.1`, NOT Cloud Run. A pre-flight
assertion confirms all three criteria genuinely fail against the real world at t0
(so the vacuous-goal guard, T2.3, does not trip — there is real work to do).

**How the build happens (over the real seams, zero-stub in lib/).** The harness
binary is the coding agent: it performs the genuine build by writing the feature
source marker (`built`) into the workspace, flipping `feature_built` red → green.
The integrate action's `:integrator` seam really rebase-merges the built feature
onto origin's `main`. The deploy action's `:deploy_cmd` seam "ships" the feature
by creating the server's backing resource serving the greeting, so the route
comes into being live — the live http_probe criteria pass only against the
deployed feature.

**What kazi did (observed, not expected).** The recorded trajectory:

```
outcome=converged  iterations=4
actions=[:dispatch_agent, :integrate, :deploy]
  iter 0: feature_built=fail greeting_endpoint=fail greeting_body=fail  converged=false  # honest start: feature absent, route 404s
  iter 1: feature_built=pass greeting_endpoint=fail greeting_body=fail  converged=false  # agent BUILT the source; route still absent
  iter 2: feature_built=pass greeting_endpoint=fail greeting_body=fail  converged=false  # landed; still not deployed -> live still 404
  iter 3: feature_built=pass greeting_endpoint=pass greeting_body=pass  converged=true   # deployed -> route live -> whole acceptance vector holds
```

1. **Failed at t0, non-vacuously.** Every acceptance criterion was RED before
   kazi did anything (feature absent, endpoint 404). The goal was real work, not
   a vacuous "already done" — the t0 guard let it through and the first persisted
   observation is all-fail.
2. **Built the feature.** The agent dispatch made `feature_built` go green
   (`greeting.feature` = `built` in the real workspace); integrate landed it on
   origin's `main` (`git ls-tree main` shows `greeting.feature`); deploy created
   the live route serving the greeting. The full creation arc:
   dispatch (BUILD) → integrate (LAND) → deploy (SHIP).
3. **Did NOT converge before the feature existed.** The objective-termination
   guard (T0.8) held for CREATION exactly as for repair: there are observed
   states (iters 1–2) where the built CODE acceptance passed but the LIVE
   greeting had not yet flipped — and the loop did NOT converge in any of them.
   Convergence was gated on the live feature, not on code-green.
4. **Converged green-and-live, persisted in order.** Only the LAST iteration is
   marked converged; the terminal vector is objectively satisfied; a final REAL
   `:httpc` request confirms the running endpoint serves `hello, kazi`.

**Evidence.** `result.outcome == :converged`,
`result.actions == [:dispatch_agent, :integrate, :deploy]`; the workspace file
`greeting.feature` = `built`; `greeting.feature` present on origin's `main`; a
direct `:httpc` GET against the live server returning the greeting; the persisted
read-model history (4 iterations) showing the all-fail t0 start, the
code-green-but-live-red gate, and exactly one converged iteration at the end.

**Conclusion: D2 acceptance holds (hermetically).** kazi builds one small real
feature from failing acceptance predicates to green-and-live: the criteria fail
at t0, kazi dispatches a build, lands it, ships it, and converges only once the
live endpoint genuinely serves the new behavior — never declaring the feature
done before it is live.

**Honesty note — the Cloud-Run caveat.** This dogfood proves the creation arc
*hermetically*: the "live" surface is a real local `:inets` server, and the
deploy step is a stub emulating `gcloud run deploy`. Production-Cloud-Run-live
(an http_probe passing against a real Cloud Run URL after a real `gcloud`
deploy) remains **T0.12**, which is human/GCP-gated and out of scope here by
design (the task forbids Go/GCP/external network so CI stays self-contained).
So D2's "to live" is met in the local-running-service sense, not yet against
production Cloud Run; that final step is tracked by T0.12. Everything behaved as
designed on the first real run; no `lib/` change was needed.

## 2026-06-21 — Slice-1 dogfood (T1.8): naive fix regresses a coupled predicate; kazi detects + escalates

**What was exercised.** The Slice-1 acceptance dogfood (UC-007), the
trustworthiness analog of the Slice-0 full-loop dogfood (T0.11/T0.12). Driven
end-to-end through the REAL `Kazi.Loop` with the REAL `Kazi.Providers.TestRunner`
(shelling out to `grep` over a real temp workspace), the REAL
`Kazi.Harness.ClaudeAdapter` (pointed at a real local "naive fix" binary via its
`:command` seam), real SQLite read-model persistence, and Noop integrate/deploy
doubles. Hermetic: own Sandbox connection, a real harness binary, a real temp
workspace — no Go, no network, no GitHub, no cloud. Test:
`test/kazi/slice1_dogfood_test.exs`.

**The scenario (a genuine coupling, not a contrived flag).** Two CODE predicates
over the temp workspace:

- `pred_a` passes iff `a.txt` contains `ok`; starts RED (`a.txt` = `broken`).
- `pred_b` passes iff `b.txt` contains `ok`; starts GREEN (`b.txt` = `ok`).

The "naive fix" harness is a real executable run with `cd: workspace`. It fixes
`pred_a` (writes `ok` into `a.txt`) but, because the predicates are coupled,
BREAKS `pred_b` as a side effect (writes `broken` into `b.txt`). This is the
canonical "a fix for predicate A breaks predicate B" (concept §5, the case
ADR-0002 rejects a single exit code for) — observed through the real provider
over a real mutated workspace, not faked with a status script. The harness is
idempotent (same edit each dispatch), so once B is red it stays red.

**What kazi did (observed, not expected).** The recorded trajectory:

```
outcome=stopped  reason=:stuck  iterations=4
actions=[:dispatch_agent, :dispatch_agent, :dispatch_agent]
  iter 0: pred_a=fail pred_b=pass      # honest start: A is real work, B green
  iter 1: pred_a=pass pred_b=fail      # naive fix flipped A green AND B red
  iter 2: pred_a=pass pred_b=fail      # failing set settles on {pred_b}
  iter 3: pred_a=pass pred_b=fail      # 3rd identical observation -> stuck
REGRESSION pred_b green@0 -> red@1 status=fail attributed=[:pred_a]
stuck_failing=[:pred_b]
```

1. **Detected the regression.** The regression detector flagged `pred_b`
   green→red between observation 0 and 1, and ATTRIBUTED it to the
   `:dispatch_agent` whose failing work-list was `[:pred_a]` — i.e. the very fix
   sent to repair A is named as the cause of B breaking. Visible in `snapshot/1`
   and read back from the persisted read-model (`ReadModel.regressions/1`,
   string-keyed on-disk form).
2. **Did NOT falsely converge.** The objective-termination guard (T0.8) held:
   the whole vector was never all-pass, because the instant the naive fix made A
   pass it made B fail. `:converged` was never reached; no persisted iteration is
   marked converged. The workspace confirms the coupling really happened
   (`a.txt` = `ok`, `b.txt` = `broken`).
3. **Escalated rather than spinning forever.** The same non-empty failing set
   `{pred_b}` persisted across the stuck window (3), the human-escalation hook
   fired exactly once with `failing == {:pred_b}`, and the loop stopped
   `:stopped` / reason `:stuck`. The iteration-budget backstop (50) was never
   reached — escalation, not budget exhaustion, ended the run. Terminal outcome,
   reason, the regression flag, and `stuck_failing` are all visible in both
   `snapshot/1` and the persisted read-model.

**Evidence.** `snapshot/1` carried the regression flag, `stuck_failing =
[:pred_b]`, and terminal state `:stopped`. The read-model carried the same
regression (queryable via `ReadModel.regressions/1`), an in-order iteration
history with NO converged iteration, and an iteration showing `pred_a :pass`
while `pred_b :fail` — the coupled regression made durable.

**Conclusion: D1 acceptance holds.** kazi catches the naive fix that trades one
green predicate for another rather than declaring false success: it detects the
regression, attributes it to the causing dispatch, refuses to converge while the
regressed predicate is red, and escalates to a human via the stuck detector. The
Slice-1 trustworthy-loop acceptance is met.

**Honesty note.** Everything behaved as designed on the first real run; nothing
needed a lib/ fix. One thing worth recording: the regression is flagged once (at
the green→red edge, iter 1) and is NOT re-flagged on subsequent identical
observations — `pred_b` stays red (red→red is not a new green→red edge), so the
single persistent flag is correct, not a missed re-detection. The loop continues
to surface that flag every iteration via `snapshot/1`/the read-model until it
escalates.

## 2026-06-22 — E4 context-injection epic shipped; pool drained

**Session:** `/loop /apply --pool`. Executed E4 (ADR-0010) end-to-end across two
waves, 8 PRs, all rebase-merged with green CI and verified on integrated main.

- **Wave 13:** T4.1 (adapter `--output-format json`: real token/cost/touched →
  budget, PR #41), T4.2 (`Kazi.Context` orientation-pack builder, deterministic +
  hermetic, PR #43), T4.5 (`Kazi.Workspace` code-review-graph MCP wiring + graph
  freshness before dispatch, PR #42).
- **Wave 14:** T4.3 (stable cacheable orientation prefix in `build_prompt`, PR #44),
  T4.4 (target `.kazi/context.md` orientation file, PR #46), T4.6 (SHA-keyed
  orientation-pack cache in the read-model + migration `20260622060000`, PR #47),
  T4.8 (per-dispatch token/cost ceiling + `truncate_evidence/2` + least-privilege
  tool/permission set, PR #45), then T4.7 (`Kazi.Loop.Digest`: bounded working-set
  digest across iterations — map memory only, never the transcript, preserving
  ADR-0008 anti-anchoring, PR #48).
- **Tests:** 372 → 495 passing (+123) across the epic; format + warnings-as-errors
  clean at every merge. T4.9 (semantic-retrieval RAG) remains deferred per ADR-0005.

**Pool drained of ready work.** Remaining incomplete tasks are not pool-eligible:
- **T0.6h** (`kind: human`) — GCP project/billing/Cloud Run provisioning. Blocks
  **T0.12**, the headline Slice-0 dogfood (idea→live production probe), which is the
  project's success bar. This human task is the critical-path blocker.
- **T3.1 / T3.5 / T3.7** — unblocked by deps (T2.6 done) but coarse Slice-3
  placeholders (NATS leases, predicate-authoring front-end, Telegram) with
  `Est: TBD` and no acceptance criteria; need `/plan` granularization into hermetic
  subtasks before agents can execute against a checkable bar. T3.2/T3.6 sit behind
  T3.1.

**Next:** either (a) complete T0.6h (human GCP setup) to unblock the T0.12 dogfood,
or (b) `/plan` the Slice-3 epic (T3.1/T3.5/T3.7) into granular tasks for a new pool wave.

## 2026-06-22 — Slice-3 epic (E3) shipped via pool; all plannable agent work done

**Session:** continuation of `/loop /apply --pool`. After granularizing the coarse
Slice-3 backlog into 16 hermetic subtasks (see the plan Change Summary + ADR-0011),
executed them end-to-end across Waves 15-18, 16 PRs (#49-#64), all rebase-merged
with green CI and verified on integrated main.

- **Wave 15:** T3.1a (lease behaviour + in-memory backend + shared conformance suite),
  T3.5a (`Kazi.Authoring.propose`), T3.6a (Phoenix LiveView skeleton + Playwright).
- **Wave 16:** T3.1b (real NATS JetStream KV lease backend; integration test gated on
  `NATS_URL`, excluded by default so `mix test` stays hermetic — added `gnat`),
  T3.1c (presence/intent snapshot), T3.2a (`Kazi.Partition` blast-radius partitioning
  reusing the T4.2 graph seam), T3.5b (approve/reject/edit workflow), T3.6b (goal board
  LiveView), T3.7a (Telegram ingress via client seam).
- **Wave 17:** T3.1d (acquire lease before dispatch), T3.2b (partition->lease-key map),
  T3.5c (CLI propose/approve), T3.6c (presence + lease-map LiveView), T3.6d (history
  timeline LiveView), T3.7b (egress pings on terminal loop events). T3.6c/T3.6d shared
  `router.ex` — merged T3.6c first; T3.6d rebased with a manual one-line router conflict
  resolution (kept both routes), re-verified green before merge.
- **Wave 18:** T3.7c (end-to-end ingress->authoring->approval->run->egress test).
- **Tests:** 372 (session start) -> 650 passing (+278 across E4 + E3), 17 `:nats`
  integration tests excluded by default; format + warnings-as-errors clean at every merge.
- **ADR-0011** added: Slice-3 operator surfaces (LiveView dashboard + Telegram bridge)
  are READ projections over the read-model + NATS and never couple into the core loop;
  both sit behind injectable seams for hermetic tests.

**Pool drained — all plannable agent work in the plan is now complete (E0-E4 + E3).**
Remaining incomplete tasks are NOT pool-eligible:
- **T0.6h** (`kind: human`) — GCP project/billing/Cloud Run provisioning. Still the
  single critical-path blocker for **T0.12**, the headline Slice-0 dogfood (idea -> live
  production probe) that is the project's success bar.
- **T4.9** — deferred semantic-retrieval/RAG adapter (ADR-0005); off by default,
  un-deferring is a deliberate user decision (adds an embeddings dependency surface).

**Next:** complete T0.6h (human GCP setup) to unblock the T0.12 live dogfood; OR opt in
to building the deferred T4.9. No other autonomous pool work remains.

## 2026-06-22 — T4.9 retrieval adapter shipped; plan fully built (only human GCP remains)

**Session:** continuation of `/loop /apply --pool`. Per user direction, un-deferred
T4.9 (the ADR-0005 pluggable memory adapter), granularized it (ADR-0012), and built
it across Waves 19-20, PRs #65-#67, all rebase-merged green.

- **T4.9a** (PR #65): `Kazi.Retrieval` behaviour + no-op default + optional
  build_prompt section, OFF by default (default output byte-identical, tested).
- **T4.9b** (PR #66): graphify-embeddings backend behind the seam; integration test
  tagged `:graphify` and excluded by default so `mix test` stays hermetic.
- **T4.9c** (PR #67): per-goal opt-in wiring + SHA-keyed snippet cache (migration
  20260622080000) reusing the T4.6 pattern; off-by-default leaves the loop unchanged.
- **Tests:** 666 -> 698 passing (+32), 18 excluded (`:nats` + `:graphify` integration
  tests); format + warnings-as-errors clean at every merge. ADR-0012 records the design.

**Plan fully built. Every buildable agent task is complete: E0 (scaffold + Slice-0
loop), E1 (trustworthy loops), E2 (creation mode), E3 (Slice-3: NATS leases,
partitioning, authoring, LiveView dashboard, Telegram), E4 (context injection),
and T4.9 (retrieval).** Cumulative this session: 372 -> 698 tests (+326).

**The ONLY remaining work is human-gated:**
- **T0.6h** (`kind: human`) — provision the GCP project + Cloud Run service + deploy
  credentials. Irreducibly human (billing/credentials). This is the sole blocker for...
- **T0.12** — the headline Slice-0 dogfood (idea -> live, verified production
  deployment), which is the project's success metric (CLAUDE.md). It cannot run until
  T0.6h lands. T0.13 already built the deployable fixture + Cloud Run deploy workflow,
  so once GCP credentials exist the dogfood is unblocked.

**Next (human):** complete T0.6h, then run T0.12 to close the idea->production loop and
hit the project's success bar. No autonomous pool work remains.

## 2026-06-22 — T0.12 Slice-0 dogfood CONVERGED (idea → live production)

kazi drove the `fixtures/deploy-target` Go service from a deliberately failing test
to a live, verified Cloud Run deployment — autonomously, end-to-end. This is the
project's success bar (CLAUDE.md): idea → production, with objective convergence.

**Run (`Kazi.Runtime.run`, goal = test_runner + http_probe, budget 8 iters):**
- iter 1: both predicates FAIL (go test `not-ok`; live `/livez` body `not-ok`) → `:dispatch_agent` — a real `claude -p` edited `healthBody "not-ok"→"ok"`.
- iter 2: code green, live still FAIL (not deployed) → `:integrate` (branch → PR #69 → rebase-merge to main).
- iter 3: landed, not deployed → `:deploy` (`gcloud run deploy --source`).
- iter 4: both PASS — live `/livez` returns `ok` → **`:converged`** (release_ref `release-kazi-deploy-target-1782167118`).
- Independently verified live: `curl https://kazi-deploy-target-2r7ah2mlpa-wl.a.run.app/livez` → `200 "ok"`; `origin/main` fixture `healthBody = "ok"` (kazi's PR #69 merged).
- Crucially, kazi REFUSED success while either predicate failed (iters 1-3 stayed non-converged) — done is objective, not the agent's opinion.

**Real defects the dogfood surfaced (all now fixed or recorded):**
- L-0001/L-0002: first Cloud-Run `--source` deploy needs `artifactregistry.admin` on the deploy SA and `cloudbuild.builds.builder` on the default compute SA.
- L-0003: Cloud Run intercepts the exact path `/healthz`; the fixture's liveness route moved to `/livez`.
- L-0004: a TOML goal-file can only express `body_match` as the string `"exact"`; the http_probe matched only the `:exact` atom, so it silently fell back to substring-contains and `"ok"` falsely passed on `"not-ok"`. Fixed in `Kazi.Providers.HttpProbe` (PR #68) + regression test; example goal corrected.
- Open follow-up (non-fatal): running via `mix run` (not `mix kazi.run`) skips the read-model migration, so this run logged `no such table: iterations` and did NOT persist evidence to SQLite. Convergence is proven by the run log + the live service; persistence works under `mix kazi.run` (which migrates on startup). Worth a guard so any entrypoint ensures the read-model schema.

**Infra note:** the `kazi-deploy` project's Domain-Restricted-Sharing org policy was
relaxed (project-scoped allValues=ALLOW) to permit `allUsers` public invoker so the
live probe can reach `/livez`. Restore it (delete the project-level override) if the
fixture no longer needs to be public.

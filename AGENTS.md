# Driving kazi (for agents)

kazi is a reconciliation controller: you declare a goal as machine-checkable
acceptance predicates, and kazi drives a coding harness in a loop until those
predicates are objectively true, stuck, or over budget. kazi is a TOOL you call,
not a harness.

## Drive kazi: MCP first, JSON-CLI fallback

PREFER the MCP server. If you speak MCP, wire kazi as an MCP server and drive its
self-describing tools -- `kazi_plan`, `kazi_approve`, `kazi_apply`, `kazi_status`,
`kazi_list_proposed` -- whose input/output schemas teach you the surface at ZERO
prose cost (ADR-0044). The installed binary serves it over stdio via the `kazi mcp`
verb; the canonical client config references that binary verb:

```json
{ "mcpServers": { "kazi": { "command": "kazi", "args": ["mcp"] } } }
```

`kazi init --with-mcp` writes exactly this `.mcp.json` into a repo, and `mix
kazi.mcp` is the development entry point that starts the SAME server. The CLI
recipe below maps one-to-one onto these tools.

FALLBACK -- the JSON-CLI shell-out. When MCP is unavailable, drive kazi over its
`--json` CLI: parse the JSON, never the prose (ADR-0023). This file is the
condensed, harness-neutral recipe; `docs/orchestrator-recipe.md` is the full
version and the source of truth.

> Every command and flag below is real. Confirm the live surface with
> `kazi help --json` and `kazi schema` rather than trusting a stale copy.

For a CODE goal the on-ramp is two verbs: `kazi plan` authors the acceptance
predicates and `kazi apply` converges them (ADR-0031/0032). `kazi apply` IS the
reconcile loop -- you do NOT wrap it in a separate outer driving pass, and you do
not add a separate launch-readiness pass afterwards: "ready" is the objective
predicate vector (including any live production probe), not a verdict inferred
after the fact. The strategy layer above kazi is your own planning workflow (ADRs,
use cases, the work breakdown, the intent); kazi turns that intent into objective
predicates and executes them. Repo hygiene (git/worktree/scratch sweeping) stays
orthogonal, not part of the converge loop.

When the user says "have kazi drive this until done" (the canonical invocation
phrase), that is the request to drive kazi: author the predicates with `kazi
plan`, then converge them with `kazi apply` until they are objectively true.

## Two-tier economics (why)

Spend expensive reasoning ONCE on what "done" means -- the acceptance predicates.
Spend cheap compute on the grind of editing until they pass. kazi's objective
termination makes the split safe: the cheap implementer cannot declare victory on
plausible-but-wrong work, because truth lives in the predicates, not in the model
doing the keystrokes. You (FRONTIER model) AUTHOR predicates; a cheap harness
(`--harness claude --model <cheap-claude-id>`) RUNS the loop; kazi holds the bar
still.

The DEFAULT recipe is in-family Claude tiering (ADR-0033/0035, amended 2026-07-08 on
fleet data): you are a frontier Claude model (e.g. `claude-opus-4-8`) authoring
predicates in this session, and you grind on the DEFAULT grind tier --
`claude-sonnet-5` (step up to `claude-opus-4-8` for harder slices) -- via
`--harness claude --model <id>`. It needs only a Claude API key: no local model, no
special hardware. The rationale is empirical and re-derivable from your own fleet:
`kazi economy --json` aggregates cost, wall-clock, and outcome percentiles per model
and goal shape from the local run registry -- consult it periodically instead of
trusting any frozen figure (the dated finding that flipped this default lives in
ADR-0035's amendment; kazi issue #924 records the vacuous-convergence failure mode
cheap-tier grinding produced). Haiku is an explicit OPT-DOWN, not the default: pin
`--model claude-haiku-4-5` yourself only for a slice you already know is trivial (a
one-line fix, a lint/format pass, a doc typo).

Local / BYOM is the SECONDARY privacy add-on: if code must never leave your hardware,
grind on a local model instead -- `--harness opencode --model <local-model>` (a local
Qwen/Llama via opencode). Same two-tier shape, no cloud; explicitly secondary.

## The loop: plan -> approve -> apply -> branch

```
plan --json -> (review) -> approve --json -> apply --harness claude --model claude-sonnet-5 --json [--stream]
                                                    |
                                       parse result, branch on next_action
```

> The verbs are `kazi plan` and `kazi apply` (ADR-0032). The old verbs `run` and
> `propose` were REMOVED in v0.6.0 (T27.9): they no longer parse and now error as
> unknown commands. Use `plan`/`apply` (and `mix kazi.apply`, not `mix kazi.run`).

### 1. author predicates -- `kazi plan --json`

`plan` is the single sanctioned predicate-authoring path. Under `--json` kazi
is NON-INTERACTIVE: it never prompts or blocks on stdin. Two modes:

caller-drafts (the agent's mode -- you already reasoned about the idea, so supply
the predicates; kazi spawns NO inner model):

```sh
kazi plan --json --predicates '{
  "name": "ship a /healthz endpoint",
  "predicates": [
    {"id": "code", "provider": "test_runner", "description": "route exists and tests pass"},
    {"id": "live", "provider": "http_probe",  "description": "GET /healthz returns 200 in prod"}
  ],
  "rationale": "a health probe for the deploy target"
}'

# or pipe the payload on stdin (under --json):
echo "$PAYLOAD" | kazi plan --json
```

The payload is a `{"name", "predicates": [...], "rationale"}` object (a bare JSON
array of predicate entries is also accepted). A positional idea is OPTIONAL here.
A payload `"goal_id"` names the drafted goal verbatim and a payload `"idea"` is
persisted as the proposal's idea (T39.1, ADR-0049); absent, kazi derives them
from `"id"`/`"name"` or generates defaults.

If a strategy/work-plan doc already exists for this work, DERIVE the predicates
from its machine-checkable acceptance-criterion lines rather than inventing them
-- those lines ARE the predicate set.

Author for the grind tier -- maximum implementable detail is the DEFAULT, not
something the operator has to ask for. The predicate `description` fields are
effectively the ONLY brief the grind model receives (the dispatch prompt is the
goal name + failing predicates + evidence; it never sees your session). Every
payload you author carries: a TASK BRIEF in the first acceptance predicate's
description (one sentence of WHY, exact files/modules to touch, the pieces
known to be missing, what NOT to change, issue/ADR numbers with "read these
first" -- a ticket a new hire could execute without asking anything); a
PROCESS contract (branch `task/<goal-id>`, small conventional commits, push
with `-u`) plus a `landed` predicate (clean tree AND `HEAD == @{u}`); ONE
requirement per predicate -- never a compound "the new test passes" check that
a partial implementation could satisfy, since the grind model authors that
test; negative-space companions for any text-presence check; and hermetic
guard predicates for what must not break (full suite, formatter). A one-line
description is an authoring bug: expand it.

kazi-drafts (hand kazi only a prose idea; it drafts the predicates for you):

```sh
kazi plan "a /healthz endpoint that returns 200" --json --yes
```

If the idea is underspecified, kazi-drafts emits a JSON error and exits non-zero
rather than hanging -- pass `--yes`, supply predicates, or sharpen the idea.

`plan --json` emits one object: `goal_id`, `proposal_ref` (the approve/reject
handle), `status`, `predicates`, `rationale`, and a `clarify` array of open gaps
(each `{id, prompt, recommended}` from the deterministic floor -- e.g. a missing
live-verification target). All carry `schema_version`.

Other plan flags: `--workspace <path>`, `--strict`, `--adr`.

### 2. review and approve -- `kazi approve --json`

Read the proposed `predicates` and `clarify` gaps. If a gap matters, re-run
`kazi plan` with it closed. When satisfied, approve the `proposal_ref` from step 1:

```sh
kazi approve <proposal-ref> --json
```

Emits `{schema_version, proposal_ref, status: "approved", goal_id}`. `kazi reject
<proposal-ref> --json` declines (kept for audit). Browse the queue with
`kazi list-proposed [--status proposed|approved|rejected] --json`.

> `kazi apply` runs the APPROVED proposal directly by its `prop-...` ref
> (T39.2, ADR-0049): carry the `proposal_ref` from step 1 through `approve`
> straight into step 3 -- no goal-file reconstruction. A goal-file path also
> works, exactly as before.

### 3. converge -- `kazi apply --harness claude --model claude-sonnet-5 --json [--stream]`

Apply the approved goal with the DEFAULT grind tier. The argument is the approved
`prop-...` proposal-ref from step 2 (or a goal-file path). The DEFAULT is
in-family Claude tiering: you authored on a frontier model, so grind on
`claude-sonnet-5`:

```sh
kazi apply <proposal-ref> --workspace <path> --harness claude --model claude-sonnet-5 --json
```

OPT-DOWN (a slice you already know is trivial): pin `--model claude-haiku-4-5`
yourself. This is a deliberate opt-down, never the default rung (see the
fleet-data note above).

SECONDARY (privacy / no-cloud): keep the grind on local hardware via opencode --
same loop, no cloud:

```sh
kazi apply <goal-file> --workspace <path> --harness opencode --model <local-model> --json
```

Three safety refusals an executing `apply` makes by default -- fix the CONDITION,
do not reflexively add the override flag:

- A `--workspace` that is a git repo's PRIMARY worktree root is refused: the
  dispatched agent's shell can reset/clean the whole checkout, destroying
  untracked state that is not this goal's to touch. Run against a dedicated task
  worktree (`git worktree add <path> <branch>`); `--allow-primary-workspace` is
  only for a throwaway checkout you accept losing.
- A goal the run registry already shows LIVE (status running, heartbeat fresher
  than ~90s) is refused: a second concurrent apply burns a second budget and
  races the first's edits. Wait or stop the first; `--allow-duplicate-run` is
  only for a deliberate re-run alongside it. A dead run's row stops blocking on
  its own once its heartbeat goes stale.
- A `--workspace` a DIFFERENT live goal already holds is refused (T59.7): two
  goals sharing one directory cross-contaminate each other's commits. Give each
  goal its own worktree (the default already does); `--allow-workspace-collision`
  is only for co-tenancy you know is safe. A dead holder ages out the same way.

By default a serial `apply` against a git repo does not edit `--workspace`
directly either (T50.1, ADR-0065 decision 1): it creates its own task worktree
off that workspace's HEAD, runs the agent and every predicate there, and
removes it on every terminal state. `--in-place` opts out and edits
`--workspace` itself, reproducing pre-T50.1 direct-edit behavior byte-identically
-- pass it only when isolation buys nothing (e.g. a throwaway clone). A
non-git workspace always runs in place; worktree isolation needs a git repo.

`--base <ref>` (T50.8, ADR-0065 decision 5) creates the task worktree from
THAT ref (e.g. `--base origin/main`) instead of the workspace's HEAD. The ref
must already resolve locally -- kazi NEVER fetches; an unknown ref is a loud
error naming it. When the DEFAULT (HEAD) base is behind its locally-known
upstream, the run warns on stderr (both SHAs + the behind-count) and proceeds;
fetch and re-run, or pass `--base` to state intent, which silences the
warning. `--in-place` + `--base` together are rejected as contradictory (an
in-place run has no worktree to base).

A worktree-isolated run that CONVERGES with commits on its task branch LANDS
them on the base -- `--workspace`'s checked-out branch -- like a parallel
partition does (T50.2, ADR-0065 decision 2): rebase-merge (push -> PR ->
rebase-merge with an `origin` remote + `gh`, a plain local rebase-merge
without), conflicts routed through the re-dispatch seam, never `git reset` /
`git clean` against the caller's checkout. The result's additive `integration`
object reports the verdict; a landing that ultimately fails exits 1 with the
work parked on a surviving task branch (`integration.task_branch`) -- never a
silent drop. Converging without committing lands nothing (the base stays
byte-identical), so give the goal a `landed` predicate if commits are part of
done. A run whose own `:integrate` action already landed the work mid-run
(ADR-0055) is not double-integrated -- the landing only touches the kazi-owned
task branch.

`--check` / `--explain` stay available without either flag.

Emits ONE terminal result object. Exit code mirrors convergence AND landing:
`0` only on `converged` whose work landed (or had nothing to land), non-zero
otherwise (same on the human and `--json` surfaces).

For a long convergence add `--stream` for a JSONL progress stream -- one
`{"event": "iteration", ...}` line per loop iteration, TERMINATED by the final
result object (the one line with NO `event` field). Read lines until you see the
object without an `event`; that is the terminal result you branch on.

### Fleets: several goal-files as one DAG -- `kazi apply --fleet <dir|manifest>`

`--fleet <path>` (T50.4/T50.5, ADR-0065 decision 3) treats the positional
argument as a fleet -- a DIRECTORY of `*.goal.toml` files (non-recursive,
sorted) or a manifest `.toml` file (`[[member]] path = "..."` entries) --
instead of a single goal-file. Each member becomes a fleet node; edges come
from an OPTIONAL per-file `[metadata] depends_on = ["<goal-id>", ...]`
(explicit) plus an INFERRED serialization edge between any two nodes whose
declared `[scope]` paths overlap (goals with no declared scope paths get no
inferred edges). `--explain` prints the fleet schedule -- nodes, kind-tagged
edges, topological frontiers -- and exits, dispatching nothing.

Without `--explain` the fleet EXECUTES: pipelined frontiers (a member
dispatches the instant its deps settle), each member in its own kazi-owned
task worktree off the shared `--workspace` base (`--base <ref>` picks the
worktree base ref; `--in-place` is rejected), converged work landing on the
base BEFORE dependents dispatch, a run-registry row per member, and an
honest-unknown per-member economy rollup in the terminal object (same
`collective`/`schedule`/`blocked` keys as a needs-DAG result, plus
`mode: "fleet"`, `members`, `economy`). `--fleet-concurrency N` caps how many
members run at once (default: unbounded within a frontier). Exit 0 only when
the fleet collectively converged. See docs/orchestrator-recipe.md ("Fleets")
and docs/schemas/collective-result.md ("The fleet shape").

### Supervised checkpoints: `--pause-between-waves` / `--resume <token>`

One mechanism, two levels (T50.3, ADR-0065 decision 3, issue #936):
`--pause-between-waves` on `apply --parallel` (a `needs`-DAG/group goal) or
`apply --fleet` stops STARTING new groups/members once the current frontier
settles (in-flight work finishes -- pipelining is untouched), persists a
checkpoint to the read-model, and exits `0` with a `paused` collective
carrying a `resume_token`. Inspect the landed work, then continue with the
SAME goal-file/fleet source plus `--resume <token>`: settled groups keep
their terminal statuses and execution continues from the next frontier. A
goal-set that changed since the pause is refused loudly ("goal file changed
since pause; re-run instead"); an unknown token is a clear error, never a
silent fresh run. Without `--parallel`/`--fleet` the flags are rejected (a
serial loop has no wave boundary); a flat goal-set with no frontiers pauses
nothing. See docs/orchestrator-recipe.md ("Supervised checkpoints").

### 4. parse and branch on `next_action`

`apply --json` gives the terminal `status` plus a derived `next_action` hint, so
you never re-derive the branch from the predicate vector:

| `status`      | `next_action`  | exit | Do |
|---------------|----------------|------|----|
| `converged`   | `done`         | 0    | Finished. Ship / report. |
| `stuck`       | `investigate`  | != 0 | Inspect the predicate vector; the same set failed N times. |
| `over_budget` | `raise_budget` | != 0 | Raise the budget and re-run, or escalate. |
| `error`       | `investigate`  | != 0 | Pre-loop failure (vacuous goal, unknown harness); read `error`, fix. |

`next_action` is a HINT -- you own the policy.

### Escalate-on-stuck: the bounded model ladder (ADR-0035)

Static default-tiering always grinds on `claude-sonnet-5`. The ADAPTIVE refinement
(amended 2026-07-08) starts on the default tier and steps UP only when kazi reports
the SAME slice not progressing, so you pay frontier rates only for the slices that
need them. The policy lives ENTIRELY in the skill -- kazi reports per-invocation
state, YOU own the ladder and the rung counter. kazi-core has NO model-selection
logic (ADR-0035 decision 1).

The ladder is capped at the frontier and STOPS there:

```
claude-sonnet-5  ->  claude-opus-4-8   (STOP; do not escalate past Opus)
```

`claude-haiku-4-5` is NOT a rung on this ladder -- it is an explicit opt-down you
choose yourself for a slice you already know is trivial, by pinning `--model
claude-haiku-4-5`. An unqualified slice should never start there: check
`kazi economy --json` (per-model, per-goal-shape cost/outcome percentiles from your
fleet's run registry) whenever you doubt the tiering call -- the measured gap that
demoted Haiku is recorded in ADR-0035's dated amendment.

Trigger (the `--json` fields, T30.3 -- `docs/tiering-signals.md`): after each
`kazi apply --harness claude --model <rung> --json`, read the terminal result and
branch by `goal_id` (the slice id; KEY your rung counter by it -- the counter is
SKILL state, never a kazi field), `status` (`converged` -> reset; `stuck` /
`over_budget` -> step up; `error` -> fix the goal, do NOT escalate), `next_action`,
and `predicates[]` (confirm the same failing set -- same slice, same bar);
`reason` / `budget_spent.exceeded` name the budget dimension on `over_budget`.

In one line: on a result for the slice's `goal_id` whose `status` is `stuck` or
`over_budget` (NOT `converged`, NOT `error`) with the same failing `predicates[]`,
increment the per-`goal_id` rung counter and re-dispatch the SAME slice with the
next `--model` UP the ladder.

- RESET on a fresh slice: a new `goal_id` starts at rung 1 (`claude-sonnet-5`),
  unless you are opting a known-trivial slice down to Haiku yourself.
- BOUNDED by kazi: escalation rides on kazi's own budget/stuck termination (each
  rung is one bounded `kazi apply`) and the ladder caps at `claude-opus-4-8`, so it
  cannot loop unboundedly -- at worst two rungs, then stop.
- DISABLE -> static tiering: pin `--model` to one rung and never step up; the recipe
  degenerates to static default-tiering (always `claude-sonnet-5`, or a deliberate
  `claude-haiku-4-5` opt-down).

The full copy-paste sh recipe (ladder + trigger + reset + cap) is in the installed
kazi SKILL.md ("Escalate-on-stuck") -- kept in lockstep with this section.

### The `[escalation]` block: the ladder as goal-file DATA (ADR-0056)

You do NOT have to own the rung counter yourself. Declare the ladder as DATA in
the goal-file and kazi walks it internally (T45.7, ADR-0056 decision 5): on a
`stuck` or `over_budget` terminal verdict against the SAME failing predicate set,
the loop re-dispatches the SAME goal at the NEXT model in the ladder instead of
terminating, bounded by the ladder length (and an optional `max_rungs` cap).

```toml
[escalation]
ladder = ["claude-haiku-4-5", "claude-sonnet-5", "claude-opus-4-8"]
max_rungs = 3
```

Rung 0 PINS the initial dispatch model, so the dispatched sequence is exactly the
declared ladder. Each rung is one bounded converge with a FRESH stuck-window and
budget (not the exhausted tail of the prior rung). kazi-core still holds NO
model-selection policy -- it only reads the declared list and a cursor; the ladder
is configuration, not inference. An ABSENT `[escalation]` block (or an empty
`ladder`) is byte-identical to today's single-model loop -- no escalation. This is
the native equivalent of the skill-side ladder above: use the block when you want
kazi to own the escalation inside one `kazi apply`; drive the ladder yourself
(re-dispatching per rung) when you want to inspect between rungs. Pinning a single
`--model` and omitting the block degenerates to static tiering, unchanged.

### Polling -- `kazi status <ref> --json`

`kazi status <ref> --json` is a PURE read of the read-model (no loop runs). The
`<ref>` resolves as a run's goal id first (`kind: "run"` -- latest predicate
vector), else a `proposal_ref` (`kind: "proposal"` -- lifecycle state). An unknown
ref is a JSON error with a non-zero exit.

## Roadmap scope: a project is a goal DAG (ADR-0056)

One `kazi plan` authors ONE goal; a project is an ordered SET of goals with
dependencies between them. The same four verbs lift one level: you author a
ROADMAP (a goal DAG), converge it, and render it -- no external plan/apply layer
is assumed or required. kazi drives the whole engineering surface from the binary
alone.

**Author a roadmap -- `kazi plan --project '<goals-json>'`.** The caller-drafts
project path (T45.2, ADR-0056 decision 1) carries a multi-goal payload the way
`--predicates` carries a single goal: a JSON object with a `"goals"` array, each
goal a per-goal predicate payload plus optional `needs` edges to other goals'
ids. kazi persists it as N linked proposals sharing ONE roadmap ref; each goal
runs the per-goal clarify floor (byte-identical to a single-goal plan) and the
roadmap runs the roadmap-scope floor. `--json` emits the roadmap ref + per-goal
proposal refs.

```sh
kazi plan --project '{
  "goals": [
    {"id": "foundation", "predicates": [ ... ]},
    {"id": "api", "needs": ["foundation"], "predicates": [ ... ]},
    {"id": "ui",  "needs": ["api"],        "predicates": [ ... ]}
  ]
}' --json
```

**Discovery on-ramp -- `kazi plan --discover`.** An OPT-IN understand-before-authoring
pass (T45.6, ADR-0056 decision 4): kazi attaches best-effort discovery evidence
(deterministic stack detection, `.feature` use-cases, a public-surface codebase
scan) to the drafted proposal, visible via `kazi status <proposal-ref> --json`.
It is kazi-drafts territory -- caller-drafts (`--predicates`/`--project`) bypass
it entirely, since a frontier session that already reasoned about the goal needs
no second model. Any discovery step failing degrades to a plain draft with a
warning, never a hard error.

**Converge a roadmap -- `kazi apply <roadmap-file>`.** Point `apply` at a roadmap
`.toml` (a `[[goals]]` DAG, T45.4/ADR-0075) and it runs the WHOLE GOALS in
topological `needs` frontiers via the same fleet-execution engine `--fleet` uses
(a roadmap projects onto a fleet). Each goal runs its OWN kazi apply loop in its
OWN task worktree, inheriting its own `[integration]` landing; converged work
lands on the base before dependents dispatch. The result is a roadmap-level
collective verdict (same `collective`/`schedule`/`blocked` shape as a needs-DAG
result). `--explain` prints the roadmap schedule and exits without dispatching; a
single-goal roadmap degrades to a plain `kazi apply` on that goal. `--in-place` is
rejected (every goal needs its own worktree).

**Render the plan document -- `kazi plan render <roadmap-file> [--out <path>]`.**
The read-model holds the facts; `plan render` (T45.5, ADR-0056 decision 3) emits
the human-readable plan (the WBS with checkboxes, waves, progress) as GENERATED
markdown from the roadmap DAG + its read-model verdicts. It is OUTPUT, never input
-- to stdout by default, or written to `--out <path>`. A hand-edit to the rendered
file is lost work by design: regenerate, never hand-edit, so the document cannot
drift from the truth it renders.

## Landing: `[integration]`, `[conventions]`, and the process contract

Convergence is not the end: a goal whose code predicates pass but whose fix is
still uncommitted is not done. kazi treats landing as part of the objective bar
(ADR-0055) and owns the universal working rules so goal-files stay declarative.
Full how-to: `docs/landing.md`.

**`[integration]` -- how converged work LANDS.** Add a block declaring `mode`
(default `none`; one of `none | commit | branch | pr | merge`):

```toml
[integration]
mode = "commit"
```

When `mode != none`, kazi SYNTHESIZES a `landed` predicate and appends it to the
vector -- an ordinary predicate evaluated against the LIVE working tree that
asserts a clean tree plus the mode-appropriate git/GitHub state (committed on a
non-base branch / pushed / open PR / rebase-merged). So "code-green with the fix
uncommitted" stays UNSATISFIED and the loop keeps going. The `:integrate` action
then verifies-then-ships (the inner agent owns its commits; a dirty tree is a
distinct error, never a silent bulk commit). Under `--parallel`, each group lands
on its own branch and the collective result carries per-group `landed:
{branch, pr, merge_commit}`; `mode = "merge"` over a `needs`-DAG merges in
topological order with `git cherry` silent-revert verification.

A drafted PROPOSAL may carry the same `integration` block, so the
plan -> approve -> apply chain lands as well (#1620) -- the proposal parser reuses
the goal-file integration parser, and the block round-trips through the persisted
proposal. To land an APPROVED proposal (or a goal-file) that declared none, override
the landing mode at apply time rather than re-authoring the goal:
`--integration <none|commit|branch|pr|merge>`, paired with `--base <ref>` for the
target branch. The flag sets the mode only; declaring `[integration]` remains the
primary path (it also synthesizes the `landed` predicate that gates convergence on
the work being committed).

**`[conventions]` -- the controller-owned process contract.** kazi appends a small,
versioned block of UNIVERSAL working rules to every dispatch prompt (small
conventional commits scoped to one directory; commit as you go; no stubs; grep
`docs/lore.md` before debugging; migration-number safety under parallelism;
network-retry; prefer graph tools). It is byte-identical across a goal's iterations
(a cacheable head) and harness-agnostic. Toggle/extend it:

```toml
[conventions]
process_contract = true                       # default; false disables the section
extra_rules = ["Run mix format before committing."]
```

`extra_rules` are appended verbatim after the universals; repo-specific style
otherwise lives in the repo's own `CLAUDE.md`/`AGENTS.md`, not the goal-file.

**Tier-0 pattern (older binaries).** If your goal-file targets a kazi binary that
PREDATES the `[integration]` block, hand-write the equivalent `landed` predicate as
a `custom_script` -- "clean tree AND HEAD ahead of `origin/main`", the manual
equivalent of `mode = "commit"`. Keep the commits small and scoped to one directory
(matching the process contract). Copy-pasteable, and it loads as-is:

```toml
[[predicate]]
id = "landed"
provider = "custom_script"
description = "clean tree AND HEAD ahead of origin/main -- manual equivalent of [integration] mode = commit"
cmd = "sh"
args = ["-c", "git status -s | grep -q . && exit 1; git diff origin/main HEAD | grep -q . || exit 1; exit 0"]
verdict = "exit_zero"
```

**The routing decision (ADR-0055).** Do NOT paste prose discipline blocks into a
goal-file -- each concern has one home: objectively-checkable rules become
PREDICATES (the `landed` predicate, the validation ladder, zero-stub); universal
how-to-work guidance is carried by the PROCESS CONTRACT (you never restate it per
goal); and mechanics (worktree isolation, branch creation, merge ordering, PR
opening) are CONTROLLER behavior. A goal-file stays a short declarative statement
of done.

## Pin `schema_version`

Every `--json` object carries `schema_version` (currently **2**, bumped by
ADR-0032 when the verbs unified) -- one shared compatibility number across all
surfaces. An additive change leaves it unchanged; a breaking change bumps it. Read
it off the first object you parse and refuse (or branch) if it is not the version
you were written against:

```sh
result=$(kazi apply "$GOAL" --workspace "$WS" --harness claude --model claude-sonnet-5 --json)
ver=$(printf '%s' "$result" | jq -r .schema_version)
[ "$ver" = "2" ] || { echo "unexpected kazi schema_version: $ver" >&2; exit 1; }
next=$(printf '%s' "$result" | jq -r .next_action)
```

A predicate is `pass` only when it genuinely held against the real world,
including LIVE predicates, which pass only post-deploy. The vector -- not a single
exit code -- makes regression and partial progress legible.

## Runtime introspection (no stale docs)

kazi self-describes; confirm the surface at runtime instead of trusting this copy:

```sh
kazi help --json              # the command/flag surface (generated from kazi's command table)
kazi schema [apply|status]    # the versioned --json result schema(s) as data
```

`kazi help --json` lists every command with its `summary`, positional `args`, and
`flags` (`name`, `type`, `description`, `aliases`) -- the verbs are `apply`/`plan`
(the `run`/`propose` aliases were removed in v0.6.0, T27.9). `kazi schema` emits the
versioned result schemas; both are JSON.

Recap (the MCP-first path at the top of this file): an MCP-speaking harness skips
the JSON-CLI shell-out entirely. `kazi mcp` starts the MCP server over stdio
(ADR-0044) -- the same server `mix kazi.mcp` runs -- and the plan / approve / apply
/ status tools self-describe through their schemas. The canonical client config is
`{ "mcpServers": { "kazi": { "command": "kazi", "args": ["mcp"] } } }`.

## Semantic recall (ADR-0062)

`kazi memory recall "<query>" [--budget <tokens>] [--json]` is a budgeted FTS
search over the project's git-native corpus (ADRs, `docs/lore.md`,
`docs/devlog.md`, `AGENTS.md`, `CLAUDE.md`, `README.md`) — the same recall the
loop can inject into a dispatch prompt (opt-in, `docs/memory.md`). Use it to
check what the project already knows before re-deriving an invariant a prior
run already recorded.

## Gated memory harvest and promotion (ADR-0063)

kazi detects candidate memory entries (deterministically, controller-side,
never from the harness/dispatch path) at run termination and stores them as
PROPOSALS -- never straight into the corpus. Review and promote them:

```sh
kazi memory list-proposed [--status proposed|approved|rejected] [--json]
kazi memory approve <proposal-ref> --workspace <path> [--json]   # writes into
                                                                  # docs/lore.md /
                                                                  # docs/devlog.md /
                                                                  # a drafted ADR
kazi memory reject <proposal-ref> [--json]                       # declined, audited
```

`approve` writes an ordinary working-tree edit (a `kx:<fingerprint>`
provenance trailer, ADR-0063); review the diff and land it like any other doc
change (ADR-0034) -- kazi never commits memory on its own authority.

## The kazi daemon + session bus (ADR-0067)

`kazi daemon start|stop|status [--json]` is the lifecycle for a long-lived,
per-machine daemon over a local Unix-socket control plane with a version
handshake, and **convergence never depends on the daemon** (a goal converges
identically with it down).

```sh
kazi daemon start           # foreground; the operator backgrounds it, same as
                             # `kazi dashboard` -- prints "listening on <sock>"
                             # then blocks until stopped, and supervises a
                             # nats-server for the session bus below
kazi daemon status [--json] # connects, pings, prints the handshake (vsn,
                             # uptime, pid); a stale socket left by a dead
                             # daemon is detected and cleaned up, never
                             # reported as "running"
kazi daemon stop [--json]   # sends a clean shutdown; exits 1 with a clear
                             # "no daemon running" line when already down
```

The socket lives at `~/.kazi/daemon/daemon.sock` (or `$KAZI_STATE_DIR`), a
pidfile alongside it at `daemon.pid`. Nothing else in kazi starts this daemon
or reaches into it -- it is opt-in operational infrastructure, not part of the
`apply` loop.

With the daemon up, `kazi bus post|read|peek|watch|who|tell` (and the matching
`kazi_bus_post` / `kazi_bus_read` / `kazi_bus_watch` / `kazi_bus_who` /
`kazi_bus_tell` MCP tools) let concurrent operator sessions and kazi runs
coordinate -- presence, shared facts, release-window broadcasts, directed
handoffs -- over a supervised NATS JetStream bus. Every message is advisory,
provenance-stamped input (never a command channel); every surface reports a
clean "no daemon" error when the daemon is down. Full concepts, subject
taxonomy, and the delivery installer: `docs/session-bus.md`.

**Delivery is installed, not documented (ADR-0076).** `kazi install-hooks`
(opt-in, the sibling of `kazi install-skill`) registers two hooks in the
Claude Code settings -- SessionStart and UserPromptSubmit run `kazi bus hook
<event>` -- so bus traffic reaches a session at its turn boundaries without
anyone polling or being reminded. It merges (never clobbers: an operator's
own hooks/keys survive byte-identically), re-running is a no-op, and
`--uninstall` removes exactly what was added; `--local` targets the repo's
LOCAL (uncommitted) settings file instead of the user-level default. `kazi
bus hook <event>` itself ALWAYS exits 0 silently -- with no daemon it is an
instant no-op, so an installed hook can never break or slow a session.

**How to wait: peek vs read vs watch.** Three distinct verbs, three intents:

- **Check without consuming** -- `kazi bus peek` (or `kazi_bus_read` with
  `peek: true`). Messages are shown but stay pending for the next read.
- **Consume** -- `kazi bus read` / `kazi_bus_read`. LANDMINE: read ACKS
  everything it pulls. A casual "let me check the bus" read silently drains
  messages a later wait was supposed to react to, and the bus then looks
  quiet. If you are not ready to act on the messages, peek instead.
- **Wait** -- `kazi bus watch --timeout <s>` / `kazi_bus_watch`. Blocks until a
  NEW message arrives, and refreshes your presence while parked. `--since`
  anchors what counts as new: `now` (the default) delivers only messages posted
  AFTER the watch starts, leaving pending backlog for `read`/`peek`; `all` is
  the drain-first behavior (T54.9). NEVER poll `read` in a loop -- watch is the
  no-poll primitive. The CLI exits 3 on timeout; the MCP tool returns
  `{ok: true, timed_out: true, digest: {total: 0, lines: []}}` -- branch on
  `timed_out`.

Cadence: check at turn boundaries (peek, or install delivery once with
`kazi install-hooks` -- see `docs/session-bus.md`); block with a bounded
`watch` only when you are genuinely waiting on another session.

**The wake contract: how an IDLE session gets woken.** Delivery lands at turn
boundaries, and an idle session has no next turn -- so a `tell` to an idle
session just sits `pending` (visible via `bus status <id>`) and nobody is
woken. Two halves, by the target's state:

- **Target is ACTIVE** -- `kazi bus tell <session> <text> --sev interrupt`. It
  has a boundary coming, and the digest renders directed/interrupt messages
  verbatim (ADR-0072).
- **You are IDLE** -- park `kazi bus watch --timeout <s> --json` as a
  BACKGROUND TASK of your harness, so its completion re-invokes you. **Arrival
  (exit 0) is the wake, with the message already in hand** -- the task's output
  IS the digest, so no follow-up read. **Timeout (exit 3) is a non-event --
  re-park.** You sleep in between, costing no tokens, and stay `active` on
  `bus who`. This needs the `--since now` default: with `--since all` a park
  fires instantly on backlog and degenerates into a poll.

kazi never wakes a session by reaching into it (no prompt injection, no driving
a TTY) -- that is permanently outside its boundary (ADR-0001/ADR-0076
non-goals). The harness's background-task mechanic is the supported wake.

**Use harness-native agent teams instead** when the sessions are ones your own
session SPAWNED (one lead, one machine, one session lifetime): teams already
deliver messages, keep a roster, and track a dependency-aware task list, so the
bus adds nothing there. The bus is for the sessions nobody spawned --
independently-started peers, cross-machine, restart-surviving,
harness-agnostic, tied to kazi's objective state. **Teams orchestrate the
workers one session spawns; the bus coordinates the sessions nobody spawned.**

## Verifying a pooled task with kazi

In a work-pool orchestration session, gate your task's MERGE on objective
convergence (ADR-0026 L1): bridge the task's acceptance line to predicates,
plan/approve, then
`kazi apply --json` -- rebase-merge ONLY when `status` is `converged`; on
`stuck` / `over_budget` / `error`, escalate and do NOT merge. Full copy-pasteable
gate (git-refs only, no NATS): `docs/pool-verification-gate.md`.

## See also

- `docs/landing.md` -- landing: `[integration]`/`[conventions]`, the process contract, the Tier-0 `landed` pattern, and the ADR-0055 routing decision.
- `docs/session-bus.md` -- the session bus: concepts, CLI/MCP surfaces, the delivery installer (ADR-0067/0071).
- `docs/pool-verification-gate.md` -- the pre-merge verification gate (ADR-0026 L1).
- `docs/orchestrator-recipe.md` -- the full recipe (source of truth).
- `docs/schemas/run-result.md`, `docs/schemas/status.md` -- the committed schemas.
- `docs/adr/0023-harness-friendly-agent-drivable-cli.md` -- the agent-drivable CLI.
- `docs/adr/0024-kazi-self-teaching-to-harnesses.md` -- self-teaching surfaces.
- `docs/adr/0031-kazi-skill-router-subsumes-loop-apply-qualify.md` -- the router on-ramp.
- `docs/adr/0032-rename-cli-verbs-run-apply-propose-plan.md` -- the verb rename.
- `docs/adr/0056-one-system-kazi-subsumes-plan-apply-skills.md` -- roadmap planning, discovery, escalation-as-data, `plan render`.
- `docs/adr/0067-session-coordination-bus.md` -- the daemon + session bus decision.

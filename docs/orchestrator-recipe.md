# Drive kazi from an orchestrating agent (the recipe)

This is the copy-pasteable recipe for an ORCHESTRATING agent -- Claude Code
today, any capable harness tomorrow -- to drive kazi programmatically through the
whole loop: author predicates -> review -> approve -> converge -> branch on the
result. The agent parses kazi's `--json` output, never its prose (ADR-0023).

**The stdout contract (ADR-0049 decision 4).** Under `--json`, stdout carries
exactly ONE JSON object (JSONL under `--stream`) on every entrypoint -- the
release binary, the escript, and a dev `mix run`. All logging goes to stderr:
the default logger handler is configured off stdout, and a `--json` invocation
additionally redirects any handler the environment pointed back at stdout
before dispatching, so even a mid-run Ecto/Phoenix log line (the "Migrations
already up" leak of issue #804) can never land ahead of the object. Parse
stdout, ignore stderr -- no "grep for the `{` line" workaround is needed.

**Pick a persistence-capable entrypoint for authoring (ADR-0049 / T39.5).**
The authoring verbs (`plan`, `list-proposed`, `approve`, `reject`) persist
proposals to the SQLite read-model, and the escript build cannot bundle the
SQLite NIF -- on the escript they refuse with a clear error naming this
limitation (exit 1; a JSON error envelope under `--json`). Drive authoring
through the release binary (GitHub release / Homebrew `kazi`) or a dev
`mix run` entrypoint. `apply`/`run` degrade to no-persistence and work
everywhere.

If you are a Claude Code user, the most ergonomic path is `kazi install-skill`
(E16, ADR-0024) -- it writes this recipe as a skill so the agent already knows
it. This doc is the source of truth that skill teaches, and the recipe any
non-Claude agent follows directly.

> Every command and flag below is real -- it is the surface emitted by
> `kazi help --json` and dispatched in `lib/kazi/cli.ex`. Introspect it at
> runtime (see "Runtime introspection" below) rather than trusting a stale copy.


## 1. The two-tier economics (why drive kazi at all)

kazi sits in the MIDDLE of a three-layer stack (concept ss4, ADR-0023):

```
  orchestrator agent  (strong model -- plan/design, AUTHOR predicates)
        |  drives kazi as a tool  (this recipe)
        v
      kazi             (the controller -- objective predicates + convergence loop)
        |  drives the inner harness
        v
  cheap implementer    (claw -> local Qwen, opencode, codex, ... -- the keystrokes)
```

Spend expensive reasoning ONCE on the part that needs judgment -- what "done"
means: the acceptance predicates. Spend cheap, local compute on the iterative
grind of editing until those predicates pass. kazi's objective termination makes
the split safe: the cheap implementer cannot declare victory on
plausible-but-wrong work, because truth lives in the controller, not in the model
doing the keystrokes. The strong brain sets the bar; the cheap brain reaches for
it; kazi holds the bar still.

The orchestrator owns the per-phase model policy. kazi bakes NONE of that tiering
in -- it just exposes the levers (`--harness` / `--model` / `--effort` per call,
structured output, the propose -> approve -> run state machine) and stays a pure
tool. `--effort <level>` (e.g. low / medium / high) forwards `claude --effort` --
a Claude-only token-economy lever (ADR-0047, parity-by-design: it is not forwarded
to other harnesses) -- and a goal-file can carry it as `[harness] effort = "..."`,
overridden by the CLI flag.


## 2. The agent-driven loop

```
  plan --json  ->  (review)  ->  approve --json  ->  apply --harness <cheap> --json [--stream]
                                                              |
                                                  parse result, branch on next_action
                                                              |
                          +------------------+----------------+----------------+
                          | done             | investigate    | raise_budget   |
                          v                  v                v                v
                       finished           inspect          raise budget,    (status: error)
                                          predicates       re-run           inspect, fix
```

### Step 1 -- propose predicates (`kazi plan --json`)

`plan` is the SINGLE sanctioned predicate-authoring path for an agent
(ADR-0023). It runs the deterministic clarify floor (a live-verification target +
scope) and persists a reviewable proposal. It has TWO drive modes; both go
through the same authoring path and the same floor.

**caller-drafts** -- the orchestrator already reasoned about the idea, so it
supplies the candidate predicates and kazi spawns NO inner model. This is the
orchestrator's mode (avoids the redundant "strong model -> kazi -> strong model"
re-draft). Supply the payload inline with `--predicates`, or on stdin under
`--json`:

```sh
kazi plan --json --predicates '{
  "name": "ship a /healthz endpoint",
  "predicates": [
    {"id": "code", "provider": "test_runner", "description": "the route exists and tests pass"},
    {"id": "live", "provider": "http_probe",  "description": "GET /healthz returns 200 in prod"}
  ],
  "rationale": "a health probe for the deploy target"
}'

# or pipe it on stdin (under --json):
echo "$PAYLOAD" | kazi plan --json
```

The payload is a `{"name", "predicates": [...], "rationale"}` object (a bare JSON
array of predicate entries is also accepted and wrapped for you). A positional
idea is OPTIONAL in caller-drafts mode -- the predicates carry the intent.

kazi honors the identity fields you supply (T39.1, ADR-0049): a payload
`"goal_id"` names the drafted goal VERBATIM (and the `proposal_ref` becomes
`prop-<goal_id>`), and a payload `"idea"` is persisted as the proposal's idea
and echoed in the `--json` result -- so the goal you author is the goal you can
name, poll, and apply. Absent those, the goal id and `proposal_ref` are derived
from the payload's own `"id"` (used verbatim) or `"name"` (slugged) -- never
from a shared placeholder -- so two differently identified payloads coexist as
distinct proposals instead of colliding onto one upsert slot. Re-proposing onto a `proposal_ref` that already
holds an **approved** proposal is refused (loudly, as a JSON error) unless you
pass `--replace`; this protects an approved goal's audit trail from being
silently reset by an unrelated draft.

**kazi-drafts** -- for a human at the CLI or a thin non-model script that hands
kazi only a prose idea; kazi spawns a harness to draft the predicates:

```sh
kazi plan "a /healthz endpoint that returns 200" --json --yes
```

Under `--json` kazi is NON-INTERACTIVE: it never prompts or blocks on stdin. If
the idea is underspecified, kazi-drafts emits a JSON error and exits non-zero
rather than hanging -- pass `--yes` to draft best-effort, supply predicates
(caller-drafts), or sharpen the idea.

`propose --json` emits a single JSON object: `goal_id`, `proposal_ref` (the
approve/reject handle), `status`, `predicates`, `rationale`, and a `clarify`
array -- the deterministic floor's open gaps (each `{id, prompt, recommended}`),
so the orchestrator sees exactly what is still missing. All carry
`schema_version`.

Useful propose flags: `--workspace <path>` (where a kazi-drafts harness drafts),
`--strict` (refuse an underspecified idea non-interactively), `--adr` (also write
an ADR-lite rationale doc).

### Step 2 -- review and approve (`kazi approve --json`)

Read the proposed `predicates` and `clarify` gaps. If a gap matters (e.g. no
live-verification predicate), re-`plan` with the gap closed. When satisfied,
approve the `proposal_ref` from Step 1:

```sh
kazi approve <proposal-ref> --json
```

`approve --json` emits `{schema_version, proposal_ref, status: "approved",
goal_id}`. On success the goal is now runnable by `kazi apply` -- pass the
`proposal_ref` straight to `apply` (Step 3, ADR-0049): no goal-file needed.

For a file-based or version-controlled workflow that WANTS a goal-file
artifact, add `--write <path>`:

```sh
kazi approve <proposal-ref> --write goal.toml --json
```

This materializes the approved goal as a loadable goal-file at `<path>` (the
full goal -- mode, standing, metadata, groups, predicates -- with NO
live-predicate scaffold, since an approved goal is complete). Under `--json`
the result gains a `path` key. `apply goal.toml` then runs the SAME goal
`apply <proposal-ref>` would; pick whichever fits your workflow. Absent
`--write`, approve is unchanged. (`kazi reject
<proposal-ref> --json` declines a proposal, kept for audit -- rejection is a
pure lifecycle transition and never requires the stored goal to still load, so
even a proposal drafted against a since-changed predicate schema rejects
cleanly; its JSON result carries `loadable: false` in that case, for audit.
`approve` is unaffected -- approving an unloadable goal stays refused.)

Browse the queue any time with `kazi list-proposed --json` (optionally
`--status proposed|approved|rejected`); it emits `{schema_version, status_filter,
count, proposals: [...]}`.

> **Anti-pattern: naked-grep predicates.** A `custom_script` predicate whose
> whole command is a bare, positive text-presence `grep` (`grep -q "..."`,
> `grep -rqiE "..."`) is satisfiable VACUOUSLY -- the fix can string-stuff the
> pattern into an unrelated file, or accidentally match pre-existing content --
> without the feature actually being built. The `clarify` array flags this as
> `naked-grep-predicate` (WARN, never a blocker) when a draft has a bare
> positive grep and no companion predicate asserting the OLD/stale pattern is
> ABSENT. Pair it with a negative-space assertion (`grep -qv <old-pattern>`),
> replace it with a structural check (parse/AST, not raw text search), or add a
> minimum-diff floor.

> Note: once approved, `kazi apply` runs the proposal DIRECTLY by its `prop-...`
> ref (T39.2, ADR-0049) -- carry the `proposal_ref` from Step 1 through `approve`
> straight into Step 3, never touching the filesystem. A goal-file path still
> works exactly as before; `plan`/`approve` themselves never write one.

> **Session provenance.** `--session-name` (or `KAZI_SESSION_NAME` /
> an auto-detected `CLAUDE_CODE_SESSION_ID`) labels whichever session
> passes it. `kazi plan --session-name <label>` records that label on the
> proposal; `kazi apply <proposal-ref>` records the proposal's own
> `proposal_ref` (and, at registration, the session that planned it) on the
> run row. The plan -> approve -> apply lifecycle is designed to be
> cross-session -- a different session may approve or apply what another
> planned -- so this is what makes that handoff traceable afterward instead
> of just inferred. A plain goal-file-path `apply` leaves the run's
> `proposal_ref` nil (unchanged behavior).

### Step 3 -- converge (`kazi apply --harness <cheap> --json [--stream]`)

Run the approved goal with the CHEAP harness (the two-tier split), by the
approved `prop-...` proposal-ref from Step 2 (or a goal-file path):

```sh
kazi apply <proposal-ref> --workspace <path> --harness opencode --model local/qwen3.6 --json
```

A non-approved ref (still `proposed`, or `rejected`) and an unknown ref are
clear errors with a non-zero exit -- approve first, then apply.

`run --json` emits ONE terminal result object on termination (the schema below).
The exit code mirrors convergence: `0` only on `converged`, non-zero otherwise --
identical on both the human and `--json` surfaces.

**Workspace semantics (ADR-0065).** By default a serial `apply` against a git
repo does NOT edit `--workspace` directly: it creates a kazi-owned task
worktree off that workspace's HEAD, the agent and every predicate run there,
and the worktree is removed on every terminal state (decision 1, T50.1). When
the run CONVERGES with commits on its task branch, those commits LAND on the
base -- `--workspace`'s checked-out branch -- exactly as a parallel partition's
do (decision 2, T50.2): rebase-merge onto the base, a conflict routed through
the re-dispatch seam bounded by an attempt budget, and NEVER `git reset` /
`git clean` against your checkout. With an `origin` remote and `gh` available
the landing is branch -> push -> PR -> rebase-merge; a local-only repo lands by
a plain local rebase-merge. The result's additive `integration` object carries
the verdict; if the landing ultimately fails, the run exits 1 even though
`status` is `converged`, and the degraded mode is a SURVIVING task branch
(`integration.task_branch`) in the base repo -- the work is never silently
dropped. An agent that converged without committing lands nothing (the base
stays byte-identical); pair the goal with a `landed` predicate to make commit
discipline part of convergence. A goal whose own `:integrate` action already
landed the work on the remote mid-run (ADR-0055, e.g. a goal with live
predicates) is not double-integrated -- the landing step only touches the
kazi-owned task branch. `--in-place` opts out of the whole indirection and
edits `--workspace` directly, pre-T50.1 style.

**Base selection and the fresh-base guard (ADR-0065 decision 5, T50.8).** By
default the task worktree is created from the workspace's current HEAD; `--base
<ref>` (e.g. `--base origin/main`) creates it from that ref instead. The ref
must already resolve in the LOCAL ref store -- kazi NEVER fetches to make a
base fresh (an implicit fetch inside a build tool is its own bug class); an
unknown ref is a loud error naming it, before any worktree exists. When the
DEFAULT base is behind what the local repo already knows about its upstream
(the checked-out branch's `@{u}`, else a locally-present `origin/HEAD` /
`origin/main`), the run WARNS on stderr -- both SHAs plus the behind-count --
and proceeds; the remedy is to fetch and re-run, or pass `--base` to state
intent, which silences the warning entirely. It is a warning, never a refusal,
and it never triggers a network call. `--in-place` + `--base` together are
rejected as contradictory: an in-place run has no worktree to base.

For a LONG convergence, add `--stream` for a JSONL progress stream -- one
`{"event": "iteration", ...}` line per loop iteration, TERMINATED by the final
run-result object (the one line with NO `event` field). Read lines until you see
the object without an `event`; that is the terminal result you branch on:

```sh
kazi apply <proposal-ref> --workspace <path> --harness opencode --json --stream
```

Under `--parallel --json --stream` against a `needs`-DAG goal (ADR-0028), the
stream ALSO carries `{"event": "frontier_complete", "frontier": N, "groups":
[...]}` lines -- one per topological wave boundary, emitted once every group in
that frontier has terminated and before the next frontier dispatches. An
orchestrator that wants to pause/inspect between waves watches for this event
instead of polling; one that only cares about the final verdict can ignore it
alongside the `iteration` events (see `docs/schemas/run-result.md`'s
"Frontier-complete event" section).

### Step 4 -- parse the result and branch on `next_action`

`run --json` gives you both the terminal `status` and a single derived
`next_action` hint, so you never re-derive the branch from the predicate vector:

| `status`      | `next_action`  | exit | What the orchestrator does |
|---------------|----------------|------|----------------------------|
| `converged`   | `done`         | 0    | Finished. Ship / report. |
| `stuck`       | `investigate`  | != 0 | Inspect the predicate vector; the same set failed N times. |
| `over_budget` | `raise_budget` | != 0 | Raise the budget and re-run, or escalate. |
| `error`       | `investigate`  | != 0 | Pre-loop failure (vacuous goal, unknown harness); read `error`, fix. |

`next_action` is an orchestration HINT, not a kazi action -- the orchestrator
owns the policy (ADR-0023).

### Polling between steps (`kazi status <ref> --json`)

`kazi status <ref> --json` is a PURE read of the read-model (no loop runs,
nothing mutates). The `<ref>` resolves as a run's goal id first, else a
`proposal_ref`. Use it to poll where a run or proposal stands between steps:

```sh
kazi status <goal-id>      --json   # kind: "run"      -- latest iteration's vector
kazi status <proposal-ref> --json   # kind: "proposal" -- lifecycle state
```

An unknown ref is a JSON error envelope with a non-zero exit.

### Fleets: several goal-files as one DAG (`kazi apply --fleet <dir|manifest>`)

Real work often spans several goal-files with cross-file dependencies. A
**fleet** (T50.4, ADR-0065 decision 3) is a DAG of goal-files, loaded from
either:

  * a DIRECTORY -- every `*.goal.toml` file in it, non-recursive, loaded in
    sorted filename order (`.kazi/goals/` convention, ADR-0059); or
  * a manifest `.toml` file -- a minimal `[[member]]` list:

    ```toml
    [[member]]
    path = "0013-first.goal.toml"

    [[member]]
    path = "0014-second.goal.toml"
    ```

    `path` is resolved relative to the manifest's own directory; an absolute
    path passes through unchanged.

Each loaded goal-file becomes a fleet NODE, keyed by its goal id (duplicate ids
across members are a load error naming both files). Two kinds of edge order the
nodes:

  * **explicit** -- an OPTIONAL `[metadata] depends_on = ["<goal-id>", ...]`
    key on a member goal-file (loaded verbatim by the existing loader onto
    `Goal.metadata` -- no goal-file schema change). A `depends_on` on an
    unknown goal id, or a cycle among explicit edges, is a load error naming
    the offending file(s).
  * **inferred (scope overlap)** -- between any two nodes whose declared
    `[scope]` paths overlap (one path prefix-contains the other) when no
    explicit edge already orders them -- the same "same blast radius = never
    concurrent" rule the in-goal-file scheduler applies, lifted across files.
    Ordered by file sequence (earlier file first). A node with NO declared
    scope paths gets NO inferred edges -- an unscoped goal does not serialize
    the whole fleet. Escape hatches: declare an explicit edge, or narrow
    `[scope] paths`/`write_paths` so two goals no longer overlap.

`--explain` prints the fleet's nodes, its kind-tagged edges (an
`inferred_overlap` edge also carries the overlapping paths), and the resulting
topological frontiers, and dispatches nothing:

```sh
kazi apply --fleet .kazi/goals/ --explain --json
```

```json
{
  "schema_version": 2,
  "mode": "fleet_explain",
  "dispatched": false,
  "nodes": [{"id": "a", "file": ".kazi/goals/0001-a.goal.toml"}, "..."],
  "edges": [
    {"from": "a", "to": "c", "kind": "explicit"},
    {"from": "d", "to": "e", "kind": "inferred_overlap", "overlap": [{"a": "lib/", "b": "lib/kazi/"}]}
  ],
  "frontiers": [["a", "b", "d"], ["c", "e"]],
  "next_action": "run without --explain to execute the fleet"
}
```

#### Executing a fleet (T50.5)

Without `--explain`, the fleet EXECUTES: the DAG runs through the partition
scheduler one level up, with pipelined frontier advancement -- a member
dispatches the INSTANT its deps settle; a still-running sibling in the same
frontier does not gate it (no wave barrier).

```sh
kazi apply --fleet .kazi/goals/ --workspace /path/to/repo --json
```

Semantics per member:

  * **worktree per goal** -- each member runs in its own kazi-owned task
    worktree created off the shared `--workspace` base's HEAD (`--base <ref>`
    selects a different base ref for every member worktree, T50.8; the
    stale-base warning applies to the defaulted HEAD exactly as in a serial
    apply). `--fleet` + `--in-place` is rejected: member isolation is the
    fleet contract. A non-git workspace runs members in place (isolation
    needs a git repo).
  * **landing before dependents** -- a converged member's COMMITTED
    task-branch work lands on the base through the serial landing (T50.2:
    rebase-merge, or PR when a remote + `gh` exist) BEFORE its terminal
    status is reported, so a dependent's worktree branches from a base that
    already carries it. A member that converged but could NOT land reports
    `stuck` (its dependents block rather than build on a base missing the
    work); the surviving task branch is named in the member's `integration`.
  * **registry + duplicate guard** -- every executing member registers its own
    run-registry row (visible to `kazi status` / the starmap), and the
    duplicate-run guard composes per member goal id: a second apply on a goal
    a live fleet member holds refuses.
  * **`--fleet-concurrency N`** -- caps how many members RUN at once (a gate
    around the member runner; DAG readiness is untouched). Default:
    unbounded within a frontier.
  * **`frontier_complete` at fleet boundaries** -- under `--json --stream`,
    each fleet frontier boundary emits the SAME JSONL `frontier_complete`
    event the `--parallel` needs-DAG path emits (one mechanism, two levels).
    The T50.3 supervised checkpoint (`--pause-between-waves` / `--resume`,
    next section) applies to fleet frontiers with the same semantics: a
    paused fleet exits 0 with `"collective": "paused"` and a `resume_token`
    in the terminal object.

The terminal object mirrors the DAG collective result (same
`collective`/`schedule`/`blocked`/`next_action` keys), with additive fleet
fields -- `mode: "fleet"`, per-member statuses, and an HONEST-UNKNOWN economy
rollup (a member whose run reported no usage contributes `null`, never
fabricated zeros; the rollup says how many members reported). See
`docs/schemas/collective-result.md` ("The fleet shape") for the full shape.
Exit code: `0` only when the collective converged (or paused with a resume
token); anything else is `1`.

### Supervised checkpoints (`--pause-between-waves` / `--resume`)

A long multi-wave run -- a `needs`-DAG goal under `--parallel`, or a fleet --
normally advances frontier to frontier unattended. The supervised-checkpoint
mode (T50.3, ADR-0065 decision 3, the full ask of issue #936) lets an operator
stop at each boundary, inspect what landed, and continue:

```sh
# 1. Run with the pause flag: the scheduler stops STARTING new groups once
#    the current frontier settles (in-flight groups finish -- pipelining is
#    untouched), persists a checkpoint to the read-model, and exits 0.
kazi apply my.goal.toml --workspace ./svc --parallel --pause-between-waves --json
```

The terminal object is the usual collective shape with
`"collective": "paused"`, the settled groups' terminal statuses (`pending` for
what a resume will pick up), and the checkpoint handle:

```json
{
  "schema_version": 2,
  "goal_id": "my-goal",
  "collective": "paused",
  "schedule": [ "..." ],
  "blocked": [],
  "resume_token": "pause-…",
  "next_action": "paused at a frontier boundary; resume by re-running with --resume <resume_token>"
}
```

```sh
# 2. Inspect at your leisure (the checkpoint survives process death -- the
#    read-model is the bridge), then continue from the next frontier:
kazi apply my.goal.toml --workspace ./svc --parallel --resume pause-… --json

# Keep --pause-between-waves on the resume to advance ONE frontier at a time.
# The same pair drives fleet frontiers:
kazi apply --fleet .kazi/goals/ --workspace ./repo --pause-between-waves --json
kazi apply --fleet .kazi/goals/ --workspace ./repo --resume pause-… --json
```

Guard rails, so a resume can never silently do the wrong thing:

  * the resumed goal-set must be BYTE-IDENTICAL to the paused one -- the token
    embeds the goal-set hash, and a mismatch refuses loudly (`"goal file
    changed since pause; re-run instead"`), exit non-zero;
  * an unknown/expired token is a clear error naming it, never a silent fresh
    run;
  * without `--parallel`/`--fleet` the flags are rejected (a serial loop has
    no wave boundary to pause at); a flat goal-set with no frontiers pauses
    nothing (the flag is a no-op, mirroring `frontier_complete`);
  * a pause is the REQUESTED outcome: exit `0`, so an orchestrator loop treats
    it as success-so-far and branches on `"collective": "paused"`.

## 3. The versioned result schemas (pin `schema_version`)

Every `--json` object carries a `schema_version` (currently **2**). It is a
COMPATIBILITY surface: an additive change (a new field) leaves it unchanged; a
breaking change (a removed/renamed field, a changed type or meaning) bumps it.
ALL `--json` surfaces share the one number, so an orchestrator pins or checks
exactly one value.

**An orchestrator MUST pin or check `schema_version`.** Read it off the first
object you parse and refuse (or branch) if it is not the version you were written
against:

```sh
result=$(kazi apply "$GOAL" --workspace "$WS" --harness opencode --json)
ver=$(printf '%s' "$result" | jq -r .schema_version)
[ "$ver" = "2" ] || { echo "unexpected kazi schema_version: $ver" >&2; exit 1; }
next=$(printf '%s' "$result" | jq -r .next_action)
```

The two committed contracts:

- **`docs/schemas/run-result.md`** -- the `kazi apply --json` terminal result
  (`schema_version`, `goal_id`, `status`, `predicates` [the predicate vector of
  `{id, verdict}`], `iterations`, `budget_spent`, `next_action`, `reason`,
  `release_ref`; an `error` field when `status` is `error`). Also documents the
  `--stream` JSONL iteration event.
- **`docs/schemas/status.md`** -- the `kazi status --json` read (`kind: "run"` or
  `kind: "proposal"`, with the run's latest predicate vector or the proposal's
  lifecycle state).

A minimal `run --json` result:

```json
{
  "schema_version": 2,
  "goal_id": "cli-e2e",
  "status": "converged",
  "predicates": [
    { "id": "code", "verdict": "pass" },
    { "id": "live", "verdict": "pass" }
  ],
  "iterations": 4,
  "budget_spent": { "iterations": 4, "exceeded": null },
  "next_action": "done",
  "reason": null,
  "release_ref": "v2026.06.23-abc1234"
}
```

A predicate is `pass` only when it genuinely held against the real world,
including LIVE predicates, which pass only post-deploy. The vector -- not a single
exit code -- is what makes regression and partial progress legible.


## 4. Runtime introspection (no stale docs)

kazi self-describes, so an agent confirms the surface at runtime instead of
trusting a copy of this recipe (ADR-0024):

- **`kazi help --json`** -- the command/flag surface as a single JSON object:
  every command with its `summary`, positional `args` (with `required`), and
  `flags` (each with `name`, `type`, `description`, `aliases`). It is GENERATED
  from kazi's own command table, so it can never drift from what the parser
  accepts.
- **`kazi schema [<command>]`** -- the versioned result schema(s) for `--json`
  output, as data (field rows + an example). With a command (`apply` or `status`),
  that command's schema; with none, all of them. JSON-only by design; an unknown
  command is a JSON error with a non-zero exit.

Introspect first, then drive:

```sh
kazi help --json   | jq '.schema_version, (.commands[].name)'
kazi schema run    | jq '.schema_version, .fields[].name'
```


## 5. The richer alternative: the MCP server (`kazi mcp`)

Shelling out and parsing JSON is universal and works with any agent. For an
MCP-speaking harness there is a richer path: the kazi **MCP server** that wraps
these same commands -- plan / approve / apply / status -- as self-describing MCP
tools (tool descriptions + input/output schemas ARE the teaching). An MCP client
lists kazi's tools and drives the plan -> approve -> apply loop natively, with no
shelling or JSON parsing.

On an installed binary the server is the `kazi mcp` verb (T33.1, ADR-0044); a
source checkout can also start it with `mix kazi.mcp` (E16, ADR-0024). Both start
the SAME server, so an MCP client config is just:

```json
{ "mcpServers": { "kazi": { "command": "kazi", "args": ["mcp"] } } }
```

It consumes the same proven JSON contract this recipe documents. For any non-MCP
agent, this recipe plus the two schemas is the complete, universal way to drive
kazi.

**The setup nudge (issue #972).** Nothing requires `.mcp.json` to declare the
`kazi` entry -- an MCP-speaking harness with no entry just silently falls back
to this JSON-CLI shell-out path. A serial `kazi apply`'s human (non `--json`)
report detects that omission and prints a one-line nudge toward `kazi init
--with-mcp` pointing back here. It shows AT MOST ONCE per project (a marker
under the workspace's `.kazi/` dir records that it fired) and never appears
under `--json` -- that surface stays pure per the stdout contract above.


## See also

- `docs/concept.md` ss4 -- the three-layer positioning.
- `docs/adr/0023-harness-friendly-agent-drivable-cli.md` -- the agent-drivable
  CLI decision (the recipe shape, the two drive modes, the result contract).
- `docs/adr/0024-kazi-self-teaching-to-harnesses.md` -- self-teaching: the skill,
  `help --json` / `schema`, `AGENTS.md`, and the `kazi mcp` / `mix kazi.mcp` server.
- `docs/adr/0044-kazi-mcp-installed-subcommand.md` -- `kazi mcp` as a first-class
  installed subcommand (the installed leg of the MCP surface).
- `docs/schemas/run-result.md`, `docs/schemas/status.md` -- the committed schemas.

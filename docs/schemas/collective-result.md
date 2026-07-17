# `kazi apply --parallel --json` collective result contract (schema_version 2)

The single, **versioned** JSON object `kazi apply --parallel --json` emits to
stdout on termination (T21.8, ADR-0027 + ADR-0023). It is the COLLECTIVE companion
to the serial `apply --json` contract (`docs/schemas/run-result.md`): where that
object reports ONE goal's loop result, this object reports the **collective verdict
over a partitioned goal-set** — the parallel scheduler's `%{collective:,
partitions:}` result rendered and versioned. (`apply` is the verb; the deprecated
`kazi run --parallel --json` alias was removed in v0.6.0, T27.9.)

`--parallel` drives the native parallel scheduler (`Kazi.Scheduler.run_goals/2`):
it partitions the goal-set by blast radius, spawns one supervised reconciler per
partition, and folds the partition statuses into a single collective verdict
(ADR-0027). The CLI only RENDERS + VERSIONS that scheduler result — it invents no
new scheduler semantics. Like every `--json` surface it is **non-interactive**
(ADR-0022/0023): kazi never prompts under `--json`.

The exit code mirrors the collective verdict the same way the serial run mirrors
its loop outcome: `0` only when the goal-set **collectively converged**, non-zero
otherwise. `--json` chooses only the output shape, never the code.

## Degenerate (single-partition) case

A **single goal**, or a goal-set the graph source finds **no blast radius** for,
degenerates to ONE partition (ADR-0027 step 1). The object then carries exactly one
`partitions` entry and `collective` equals that partition's status — the serial
single-goal outcome, surfaced through the collective shape. This is the on-ramp:
the same path serves one goal and N.

## Compatibility

`schema_version` is a compatibility surface shared with the serial `apply --json`
contract (one number an orchestrator pins). An additive change (a new field) leaves
it unchanged; a **breaking** change (a removed/renamed field, a changed type or
meaning) bumps it.

Current version: **2** (bumped by ADR-0032 with the apply/plan verb rename).

## Shape

```json
{
  "schema_version": 2,
  "goal_id": "cli-parallel",
  "collective": "converged",
  "partitions": [
    {
      "partition_id": "k-a1b2c3",
      "goal_ids": ["cli-parallel"],
      "status": "converged",
      "landed": { "branch": "kazi-partition/p-k-a1b2c3-9f8e", "pr": "pr-k-a1b2c3", "merge_commit": "sha-k-a1b2c3" }
    }
  ],
  "next_action": "done"
}
```

The `landed` object is ADDITIVE and present only when the partition landed (T44.10);
a run with no `[integration]` landing omits it, leaving the entry byte-identical to
the pre-T44.10 shape.

## Fields

| Field            | Type             | Meaning |
|------------------|------------------|---------|
| `schema_version` | integer          | The contract version (shared with `run-result.md`). Bumped on a breaking change. |
| `goal_id`        | string           | The goal-set's goal id — the run's handle. |
| `collective`     | string (enum)    | The COLLECTIVE verdict — one of `converged`, `stuck`, `over_budget`, or (under `--pause-between-waves`, T50.3/ADR-0065) `paused`. The orchestrator's primary branch. |
| `partitions`     | array of objects | **FLAT goals only.** One entry per partition, in the scheduler's input order. A single-partition goal-set yields exactly one entry (the serial degenerate). |
| `schedule`       | array of objects | **DAG goals only (T23.6).** The TOPOLOGICAL frontiers the scheduler took — one entry per wave, in order, each naming the groups that ran in it and their convergence state. Present iff the goal declares `needs` edges (ADR-0028). |
| `blocked`        | array of objects | **DAG goals only (T23.6).** The BLOCKED sub-DAG: one entry per group an unsatisfiable `needs` dependency poisoned, naming the blocking dep. `[]` when nothing is blocked. |
| `next_action`    | string (enum)    | An orchestration **hint** derived from `collective` — `done`, `investigate`, `raise_budget`, or the paused-run resume hint. NOT a kazi action; the orchestrator owns the policy (ADR-0023). |
| `resume_token`   | string           | **Paused DAG/fleet runs only (T50.3, ADR-0065 decision 3, ADDITIVE).** The persisted checkpoint's handle: `collective` is `"paused"`, the exit code is `0`, and re-running with `--resume <token>` (same goal-set) continues from the next frontier. Absent on a run that did not pause. |

A goal carries EITHER `partitions` (flat, no `needs`) OR `schedule` + `blocked`
(a `needs`-DAG over its groups), never both. Both shapes share `schema_version`,
`goal_id`, `collective`, and `next_action`, so an orchestrator branches on those
identically regardless of shape.

### `partitions[]`

| Field          | Type            | Meaning |
|----------------|-----------------|---------|
| `partition_id` | string          | The partition's stable lease key (`Kazi.Scheduler.Partitioner` `:key`): overlapping partitions share it, disjoint partitions differ. Falls back to `partition-<index>` for an unkeyed partition term. |
| `goal_ids`     | array of string | The ids of the `%Kazi.Goal{}` member goals this partition carries, so a partition verdict maps back to its goals. |
| `status`       | string (enum)   | This partition's terminal reconciler status — one of `converged`, `stuck`, `over_budget`, `stopped`, `crashed` (`Kazi.Scheduler.partition_status/0`). |
| `landed`       | object          | **T44.10 (ADR-0055), ADDITIVE, present only when this partition LANDED.** The per-group landing refs for a converged partition that landed its work on its OWN group-derived branch (`<branch_prefix>/<slug>`, reusing the worktree layer's `slug_for/1`, distinct per group). Keys are the refs the integrator returned: `branch` (the group's landing branch), `pr` (its PR number/handle), `merge_commit` (the resulting merge commit) — each present only when the integrator supplied it. **Absent** when the run performed no landing (`[integration]` mode `none`, or no integration configured), so the partition entry is byte-identical to the pre-T44.10 shape. This is the flat-partition analogue of the fleet member's `integration` object. |

### `collective`

The pure fold the scheduler computes over the per-partition statuses
(`Kazi.Scheduler.collective_verdict/1`), order-independent and total:

| Value         | When |
|---------------|------|
| `converged`   | **Every** partition converged (collective success). Exit `0`. |
| `over_budget` | **Any** partition hit a hard budget ceiling — surfaced first as the most actionable "we spent the budget" signal. Exit non-zero. |
| `stuck`       | Otherwise — some partition did not converge (a stuck / stopped / crashed reconciler). Investigate. Exit non-zero. |
| `paused`      | **DAG/fleet runs under `--pause-between-waves` only (T50.3, ADR-0065):** the run stopped at a frontier boundary as REQUESTED — settled groups keep their terminal statuses, the rest report `pending`, and `resume_token` carries the checkpoint handle. Exit `0` (a pause is the requested outcome, not a failure). |

An empty goal-set converges vacuously (nothing failed); a single partition's
verdict is exactly that partition's status (the serial degenerate case).

### `next_action`

A single hint derived purely from `collective`, so the orchestrator never
re-derives the branch from the per-partition vector:

| `collective`  | `next_action`  |
|---------------|----------------|
| `converged`   | `done`         |
| `over_budget` | `raise_budget` |
| `stuck`       | `investigate`  |
| `paused`      | the resume hint — `paused at a frontier boundary; resume by re-running with --resume <resume_token>` (the fleet shape words it per fleet frontier) |

This is the SAME hint vocabulary the serial `apply --json` result uses (ADR-0023),
so an orchestrator branches on `next_action` identically across the serial and
collective surfaces.

## DAG goals: the `schedule` + `blocked` shape (T23.6, ADR-0028)

When the goal declares `needs` edges over its `[[group]]` taxonomy (ADR-0028), the
scheduler runs the groups TOPOLOGICALLY — frontier by frontier, with blast-radius
parallelism inside each frontier — instead of one flat partition pass. The
collective object then carries `schedule` (the frontier order each group ran in +
its state) and `blocked` (the unsatisfiable sub-DAG) in place of `partitions`:

```json
{
  "schema_version": 2,
  "goal_id": "cli-chain",
  "collective": "stuck",
  "schedule": [
    { "frontier": 0, "groups": [{ "group": "a", "state": "stuck" }] },
    { "frontier": 1, "groups": [{ "group": "b", "state": "blocked" }] },
    { "frontier": 2, "groups": [{ "group": "c", "state": "blocked" }] }
  ],
  "blocked": [
    { "group": "b", "blocked_by": "a", "reason": "stuck" },
    { "group": "c", "blocked_by": "a", "reason": "stuck" }
  ],
  "next_action": "investigate"
}
```

### `schedule[]`

The topological FRONTIERS the scheduler took — the PURE `needs`-DAG layering
(`Kazi.Goal.DepGraph`): frontier 0 is every group with no `needs`; each later
frontier is the groups whose every `needs` dep converged in an earlier frontier. A
goal with NO `needs` is a single frontier (every group parallel); a chain is N
frontiers (one group each).

| Field      | Type            | Meaning |
|------------|-----------------|---------|
| `frontier` | integer         | The 0-based wave index, in topological order. |
| `groups`   | array of object | The groups that ran in this frontier, in declared order — each `{group, state}`. |

`groups[].state` is the group's observed convergence state — one of `converged`,
`stuck`, `over_budget`, `blocked`, `pending`, `running` (terminal once the run
ends). A group never dispatched because a dep blocked it is `blocked`.

### `blocked[]`

The BLOCKED sub-DAG (`Kazi.Goal.DepGraph.blocked/2`): one entry per group an
unsatisfiable `needs` dependency poisoned, so the report NAMES the blocking dep
rather than hanging silently (the `/apply` wave-stall failure mode, made
observable). `[]` when nothing is blocked.

| Field        | Type          | Meaning |
|--------------|---------------|---------|
| `group`      | string        | The blocked dependent's group id. |
| `blocked_by` | string        | The nearest transitive `needs` dep in a non-converging terminal state that makes this group unsatisfiable. |
| `reason`     | string (enum) | That blocking dep's state — `stuck`, `over_budget`, or `blocked`. |

## The fleet shape (T50.5, ADR-0065 decision 3)

`kazi apply --fleet <dir|manifest> --json` executes a DAG of GOAL-FILES (see
`docs/orchestrator-recipe.md`, "Fleets") and terminates with the SAME collective
shape one level up: `schema_version` / `collective` / `schedule` / `blocked` /
`next_action` keep their DAG meaning with fleet MEMBERS (goal ids) in place of
groups; `mode`, `fleet`, `members`, `economy`, and `resume_token` are ADDITIVE.
The schedule is the same `Kazi.Goal.DepGraph` layering the fleet scheduler ran,
so the report and the execution can never disagree on a member's frontier.

```json
{
  "schema_version": 2,
  "mode": "fleet",
  "fleet": ".kazi/goals/",
  "collective": "converged",
  "members": [
    {
      "id": "a",
      "status": "converged",
      "economy": { "iterations": 2, "elapsed_ms": 41200, "tokens": 18240 },
      "integration": { "landed": true, "base": "main", "task_branch": "kazi-partition/p-a-12" },
      "error": null
    },
    { "id": "b", "status": "converged", "economy": null, "integration": null, "error": null },
    { "id": "c", "status": "converged", "economy": null, "integration": null, "error": null }
  ],
  "schedule": [
    { "frontier": 0, "groups": [{ "group": "a", "state": "converged" }, { "group": "b", "state": "converged" }] },
    { "frontier": 1, "groups": [{ "group": "c", "state": "converged" }] }
  ],
  "blocked": [],
  "economy": {
    "members_total": 3,
    "members_reported": 1,
    "totals": { "iterations": 2, "elapsed_ms": 41200, "tokens": 18240 }
  },
  "resume_token": null,
  "next_action": "done"
}
```

| Field          | Type            | Meaning |
|----------------|-----------------|---------|
| `mode`         | string          | `"fleet"` — distinguishes the fleet terminal object from a single-goal collective result. |
| `fleet`        | string          | The fleet source as given: the directory or manifest path. |
| `members[]`    | array of object | One entry per member goal in loaded order: `{id, status, economy, integration, error}`. `status` uses the partition-status vocabulary (`converged` / `stuck` / `over_budget` / `stopped` / `crashed` / `blocked`, plus `pending` on a paused run). `economy` is the member's observed spend, or `null` when its run reported no usage (honest-unknown, ADR-0046). `integration` is the T50.2 landing info (`landed`, `base`, `task_branch`, ...) for a worktree-isolated converged member, or `null`. A member that converged but could NOT land reports `stuck` with `integration.landed = false` naming the surviving task branch. |
| `economy`      | object          | The fleet rollup: `members_total`, `members_reported` (how many members contributed a spend), and `totals` — the dimension-wise sum over REPORTING members only, or `null` when none reported (never fabricated zeros). |
| `resume_token` | string \| null  | Set when the run PAUSED at a fleet frontier boundary (the T50.3 checkpoint, one level up); `collective` is then `"paused"` and the exit code is `0`. |

`schedule` and `blocked` are exactly the DAG shapes documented above, with member
goal ids as the group ids. Under `--json --stream`, fleet frontier boundaries emit
the same `frontier_complete` JSONL event as a `needs`-DAG run — one mechanism,
two levels.

## Streaming (`--json --stream`): `frontier_complete` at wave boundaries (issue #936)

Under `apply --parallel --json --stream` (a `needs`-DAG/group goal) and
`apply --fleet --json --stream`, stdout is a **JSONL stream**: one
`frontier_complete` event line at each wave boundary — the moment every
group (or fleet member) of a topological frontier has settled, before a later
frontier's work dispatches — terminated by the terminal collective object.
The event shape (shared with the serial contract's stream section,
`docs/schemas/run-result.md` "Streaming progress"):

```json
{ "schema_version": 2, "event": "frontier_complete", "frontier": 0, "groups": [ { "id": "a", "status": "converged" } ] }
```

Every event line carries `schema_version` 2 and an `event` key; the terminal
object — this document's collective (or fleet) shape — has **no** `event` key
and ends the stream: read lines until the object without an `event`, then
branch on its `collective`. Per-ITERATION `"event": "iteration"` lines are the
SERIAL stream's granularity (one loop, one goal — see run-result.md); the
collective stream reports at the frontier granularity. A paused run
(`--pause-between-waves`, ADR-0065 decision 3) ends its stream with the
`"collective": "paused"` terminal object carrying the `resume_token`, after
the final settled frontier's `frontier_complete` line.

## `apply --explain` / `--dry-run`: the schedule, dispatched nothing (T23.6)

`kazi apply <goal> --explain` (alias `--dry-run`) is PURE PLANNING: it computes the
wave schedule — the topological `needs`-DAG frontiers + the blast-radius
PARTITIONING within each frontier — PRINTS it, exits `0`, and **dispatches
nothing** (no reconciler, harness, lease, or worktree is touched). It makes
over-constraint visible BEFORE a run: too many `needs` edges serialize everything
into many one-group frontiers. Under `--json` it emits a single schedule object:

```json
{
  "schema_version": 2,
  "goal_id": "cli-chain",
  "mode": "explain",
  "dispatched": false,
  "frontiers": [
    {
      "frontier": 0,
      "groups": ["a"],
      "partitions": [{ "partition_id": "k-…", "goal_ids": ["a"] }]
    },
    { "frontier": 1, "groups": ["b"], "partitions": [{ "partition_id": "k-…", "goal_ids": ["b"] }] }
  ],
  "next_action": "schedule"
}
```

| Field        | Type            | Meaning |
|--------------|-----------------|---------|
| `mode`       | string          | `"explain"` — distinguishes the dry-run object from a real collective result. |
| `dispatched` | boolean         | Always `false` — the no-execution contract, machine-checkable. |
| `frontiers`  | array of object | The computed waves: each `{frontier, groups, partitions}`. `partitions` is the blast-radius parallelism WITHIN that frontier (one entry = one parallel unit; overlapping groups share one). |
| `next_action`| string          | Always `"schedule"` — this was a plan, not a run. |

## Human surface

Without `--json`, `apply --parallel` prints a legible collective block instead of
the JSON object. For a FLAT goal — the overall verdict and one line per partition:

```
COLLECTIVE CONVERGED  goal=cli-parallel
partitions: 1
  [0] k-a1b2c3: converged  landed=kazi-partition/p-k-a1b2c3-9f8e pr=pr-k-a1b2c3 merge=sha-k-a1b2c3
```

The `landed=<branch> pr=<n> merge=<sha>` suffix (T44.10) appears only for a
partition that landed; a run with no landing prints the bare `[i] <id>: <status>`
line unchanged.

For a DAG goal — the verdict and the per-frontier schedule (plus a blocked block
when a sub-DAG is poisoned):

```
COLLECTIVE STUCK  goal=cli-chain
frontiers: 3
  frontier 0: a(stuck)
  frontier 1: b(blocked)
  frontier 2: c(blocked)
blocked: 2
  b blocked by a (stuck)
  c blocked by a (stuck)
```

`apply --explain` prints the dry-run schedule and dispatches nothing:

```
SCHEDULE (dry-run, nothing dispatched)  goal=cli-chain
frontiers: 3
  frontier 0: a
    parallelism: 1 partition(s)
    [0] k-a1b2c3: a
  frontier 1: b
    parallelism: 1 partition(s)
    [0] k-d4e5f6: b
  frontier 2: c
    parallelism: 1 partition(s)
    [0] k-7a8b9c: c
```

The exit code is identical on both surfaces; `--json` chooses only the shape.

# `kazi run --json` result contract (schema_version 1)

The single, **versioned** JSON object `kazi run --json` emits to stdout on
termination (ADR-0023 decision 2). It is the machine surface an orchestrating
agent branches on — it parses this object, never prose. Human output stays the
default; `--json` is opt-in and additive.

The object renders the convergence loop's **own** terminal result
(`Kazi.Loop.result/0`): nothing is re-derived or re-run. One JSON object is
emitted on stdout and the process exits `0` on convergence, non-zero otherwise.
The exit code is the same on both surfaces; `--json` chooses only the output
shape.

## Compatibility

`schema_version` is a compatibility surface. An additive change (a new field)
leaves it unchanged; a **breaking** change (a removed/renamed field, a changed
type or meaning) bumps it. An orchestrator recipe should pin or check
`schema_version`.

Current version: **1**.

## Shape

```json
{
  "schema_version": 1,
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

## Fields

| Field            | Type                | Meaning |
|------------------|---------------------|---------|
| `schema_version` | integer             | The contract version. Bumped on a breaking change. |
| `goal_id`        | string              | The goal's id. |
| `status`         | string (enum)       | The terminal status — one of `converged`, `stuck`, `over_budget`, `error`. The orchestrator's primary branch. |
| `predicates`     | array of objects    | The **predicate vector**: one `{ "id", "verdict" }` per predicate at the terminal observation, sorted by `id` for a stable diff. |
| `iterations`     | integer             | The loop's observation count. |
| `budget_spent`   | object              | What the run consumed: `{ "iterations": integer, "exceeded": string\|null }`. `exceeded` names the budget dimension only when `status` is `over_budget`, else `null`. |
| `next_action`    | string (enum)       | An orchestration **hint** — `done`, `investigate`, or `raise_budget`. NOT a kazi action; the orchestrator owns the policy (ADR-0023). |
| `reason`         | string \| null      | The loop's stop reason — the exceeded budget dimension (e.g. `max_iterations`, `wall_clock`, `token_budget`) or `stuck`. `null` on a clean converge. |
| `release_ref`    | string \| null      | The release tag of the artifact deployed this run (T3.3c), or `null` if nothing was deployed. |
| `error`          | string              | Present **only** when `status` is `error`: a human-readable failure message (a pre-loop failure, e.g. a vacuous goal or an unknown provider/harness). |

### `status`

| Value          | Loop outcome                          | When |
|----------------|---------------------------------------|------|
| `converged`    | `:converged`                          | The whole predicate vector is satisfied (success). Exit `0`. |
| `stuck`        | `:stopped` (reason `:stuck` or other) | The loop stopped before converging — a stuck stop (T1.5: the same failing set persisted across N iterations) or any other non-converged halt (operator/await stop). Investigate. Exit non-zero. |
| `over_budget`  | `:over_budget`                        | A hard budget ceiling was hit (T1.4); `reason` / `budget_spent.exceeded` name the dimension. Exit non-zero. |
| `error`        | _(pre-loop failure)_                  | The run could not start — a vacuous goal (R3), an unknown provider/harness, or an await timeout. The object carries `error`. Exit non-zero. |

### `next_action`

A single hint derived purely from `status`, so the orchestrator never re-derives
the branch from the predicate vector:

| `status`       | `next_action`   |
|----------------|-----------------|
| `converged`    | `done`          |
| `over_budget`  | `raise_budget`  |
| `stuck`        | `investigate`   |
| `error`        | `investigate`   |

### `predicates[].verdict`

The predicate's status string at the terminal observation: `pass`, `fail`,
`error`, or `unknown` (see `Kazi.PredicateResult`). A predicate is `:pass` only
when it genuinely held against the real world (including live predicates, which
pass only post-deploy). The vector — not a single exit code — is what makes
regression and partial progress legible (ADR-0002).

## Error object

When `status` is `error` the object substitutes the run-result fields with a
failure envelope on the **same** stdout stream, so the orchestrator parses one
surface and branches on the non-zero exit:

```json
{
  "schema_version": 1,
  "goal_id": "cli-vacuous",
  "status": "error",
  "error": "goal is vacuous — every predicate already passes at t0 ...",
  "reason": "vacuous_goal",
  "next_action": "investigate"
}
```

## Streaming progress (JSONL) — `run --json --stream` (T15.4, ADR-0023 decision 3)

`kazi run --json --stream` emits a **JSONL stream** instead of a single object:
one JSON object **per line** per loop iteration, **terminated** by the
single run-result object above. Each line parses **independently**, so an
orchestrator monitors a long convergence line-by-line without blocking — mirroring
how kazi itself parses opencode/codex JSONL.

Without `--stream`, `run --json` emits exactly the one terminal result object
(unchanged); `--stream` is opt-in and additive and only changes what precedes that
object.

### Iteration event

Each progress line is a `Kazi.Loop` observation rendered as:

```json
{ "schema_version": 1, "event": "iteration", "iteration": 0, "predicates": [ { "id": "code", "verdict": "fail" }, { "id": "live", "verdict": "fail" } ], "converged": false, "release_ref": null }
```

| Field            | Type             | Meaning |
|------------------|------------------|---------|
| `event`          | string           | Always `"iteration"`. **Distinguishes a progress line from the terminal result object**, which carries NO `event` field. |
| `iteration`      | integer          | The 0-based observation index (matches the read-model's `iteration_index`). Non-decreasing across the stream. |
| `predicates`     | array of objects | The predicate **vector** at this observation — the same `{ "id", "verdict" }` shape (sorted by `id`) as the terminal result. |
| `converged`      | boolean          | Whether the whole vector was satisfied at this observation. |
| `release_ref`    | string \| null   | The release ref recorded so far this run (T3.3c), or `null`. |
| `schema_version` | integer          | The contract version, same as the result object. |

### Stream shape

```
{ "event": "iteration", "iteration": 0, ... }   ← one per observation
{ "event": "iteration", "iteration": 1, ... }
...
{ "schema_version": 1, "status": "converged", ... }   ← the terminal result object (no "event"), the stream terminator
```

The consumer reads lines until it sees the object **without** an `event` field —
that is the terminal `run --json` result documented above, carrying the final
`status` / `next_action` / `budget_spent` the orchestrator branches on.

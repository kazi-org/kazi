# `kazi portfolio --json` schema (schema_version 2)

The single, **versioned** JSON object `kazi portfolio --json` emits to stdout —
the fleet's sitrep, composed ONLY from kazi's own objective surfaces
(read-only-projection line, ADR-0011): proposed goals (`list-proposed`), the
run registry, the attention queue, and the cross-machine bus facts. No manual
curation, no new task-management data model — every entry traces to an
existing objective source (`Kazi.Portfolio.build/0`).

Human output stays the default (a headline percentage line, each bucket's
top-3 one-liners + `--full` for the complete ledger, then the honest
fleet-wide rate); `--json` is opt-in and additive.

## Compatibility

`schema_version` is shared with the other `--json` contracts (`run-result.md`,
`status.md`): a breaking change to any `--json` surface bumps the one number
an orchestrator pins. Current version: **2**. v1 keys (`planned`, `by_repo`,
`fleet_remote`, T60.4 #1160) are byte-identical; `totals`/`todo`/`blocked`/
`rate` (E64/T64.3) are purely additive — `schema_version` stays 2 for either
shape.

## Shape

```json
{
  "schema_version": 2,
  "kind": "portfolio",
  "planned": [
    { "proposal_ref": "prop-ship-healthz-abc1234", "goal_id": "ship-healthz", "idea": "ship a healthz endpoint", "status": "proposed" }
  ],
  "by_repo": {
    "kazi-org/kazi": {
      "complete": [ { "goal_ref": "done-1", "run_id": "run-1", "status": "converged" } ]
    }
  },
  "fleet_remote": [
    { "goal_ref": "remote-goal", "bucket": "in_progress", "machine": "host2" }
  ],
  "totals": {
    "base": 13,
    "empty": false,
    "rows": [
      { "bucket": "done", "count": 5, "pct": 39 },
      { "bucket": "running", "count": 3, "pct": 23 },
      { "bucket": "blocked", "count": 2, "pct": 15 },
      { "bucket": "todo", "count": 2, "pct": 15 },
      { "bucket": "planned", "count": 1, "pct": 8 }
    ]
  },
  "todo": [
    { "proposal_ref": "prop-todo-1", "goal_id": "todo-1", "idea": "an idea", "status": "approved" }
  ],
  "blocked": [
    {
      "goal_ref": "stuck-probe",
      "run_id": "run-9",
      "status": "stuck",
      "cause": "stuck",
      "red_predicates": [ { "id": "probe", "red_iterations": 3 } ],
      "blocker": "blocked: probe red 3 iterations"
    }
  ],
  "rate": { "green": 5, "total": 8, "delta": 1, "empty": false }
}
```

| Field              | Type             | Meaning |
|--------------------|------------------|---------|
| `schema_version`   | integer          | The contract version. |
| `kind`             | string           | Always `"portfolio"`. |
| `planned`          | array of objects | Proposals `proposed`/`approved` but not yet applied: `{proposal_ref, goal_id, idea, status}`. Not grouped by repo — a proposal carries no workspace until applied. |
| `by_repo`          | object           | LOCAL runs (which DO carry a workspace) grouped by repo, then by bucket (`"in_progress"` / `"stuck"` / `"complete"`): `{repo => {bucket => [{goal_ref, run_id, status}]}}`. |
| `fleet_remote`     | array of objects | Runs in flight on OTHER machines, read from the cross-machine bus facts Mission Control's remote cards use: `{goal_ref, bucket, machine}`. Degrades to `[]` when the daemon is unreachable — never an error (ADR-0011 §2). |
| `totals`           | object           | The five-bucket headline: `{base, empty, rows}`. See [Totals](#totals). |
| `todo`             | array of objects | Approved proposals with no registered run yet (ready to dispatch): `{proposal_ref, goal_id, idea, status}`. |
| `blocked`          | array of objects | Stuck/over_budget/error runs plus DAG-blocked roadmap goals, each naming WHY (T64.2). See [Blocked](#blocked). |
| `rate`             | object           | The fleet-wide honest rate (never a projected date, ADR-0046): `{green, total, delta, empty}`. |

## Totals

`{base, empty, rows}`: `base` is the count of every bucketed item across the
five buckets (`done`/`running`/`blocked`/`todo`/`planned`); `empty` is `true`
when `base == 0` (nothing tracked yet); `rows` is one `{bucket, count, pct}`
entry per bucket in headline order (`done` first), with `pct` an INTEGER
percentage apportioned by largest-remainder so the row percentages always sum
to exactly 100.

## Blocked

Every blocked entry carries `{goal_ref, cause, blocker}` plus cause-specific
fields, so a caller can render or branch on WHY without re-deriving it:

| `cause`       | Extra fields                                    |
|---------------|--------------------------------------------------|
| `"over_budget"` | `iterations` (the recorded count), `cap` (the run's `max_iterations`). |
| `"stuck"` / `"error"` | `red_predicates`: `[{id, red_iterations}]` — the persistently-red predicate slice from the run's last recorded vector. |
| `"dag"`       | `blocked_by` — the upstream roadmap group id blocking this one. |

`blocker` is the rendered one-line human string (the same text the CLI's
`--full` ledger prints), e.g. `"blocked: probe red 3 iterations"`.

## Rate

`{green, total, delta, empty}`: `green`/`total` are predicates green out of
predicates measured in the LAST recorded vector across every `running` goal,
pooled; `delta` is the net red→green movement (green in the last vector minus
green in the first) summed across running goals; `empty` is `true` when no
running goal has a recorded rate yet. Never a projected date or ETA
(ADR-0046) — rate is rendered AS rate.

# `kazi status --json` schema (schema_version 2)

The single, **versioned** JSON object `kazi status <ref> --json` emits to stdout
(T15.5, ADR-0023 decision 2). `status` is a **pure read** of the read-model — no
loop is driven and nothing is mutated — that reports the CURRENT state of a run or
a proposal so an orchestrator can poll where a run/proposal stands between steps of
the plan → approve → apply state machine (`plan`/`apply` are the primary verbs;
`propose`/`run` are deprecated aliases, ADR-0032).

Human output stays the default; `--json` is opt-in and additive. The exit code is
the same on both surfaces: `0` when the ref resolves, non-zero on an unknown ref.

## Compatibility

`schema_version` is shared with the `apply --json` contract (`docs/schemas/run-result.md`):
a breaking change to any `--json` surface bumps the one number an orchestrator
pins. Current version: **2** (bumped by ADR-0032 with the apply/plan verb rename).

## Ref resolution

The positional `<ref>` is **optional**. With no `<ref>` at all, `status` reports
every currently **LIVE** run (`kind: "live_runs"`, below) — the pre-upgrade check
(issue #971). With a `<ref>`, it resolves in order:

1. a **run**'s `goal_ref` (a goal id the loop has recorded iterations for) →
   `kind: "run"`, the latest iteration's state; otherwise
2. a **proposal**'s `proposal_ref` (an authoring handle) → `kind: "proposal"`, its
   lifecycle state.

An unknown ref is the error object below with a non-zero exit.

## Live-run list (`kind: "live_runs"`, no `<ref>`)

`kazi status` with **no** `<ref>` argument lists every run
`Kazi.ReadModel.RunRegistry.list_live/1` currently considers LIVE: `status ==
"running"` AND a heartbeat fresher than the registry's existing staleness
window (`stale?/2`'s `@stale_after_seconds`, 90s) — the SAME staleness
definition the fleet dashboard uses, not a new one. This is the intended
pre-upgrade check: run it before `brew upgrade`/reinstalling a newer
burrito-built `kazi` binary, and wait until it reports `"count": 0` (see
`docs/lore.md`, Release / CI / Burrito, L-0036, for why installing over a
LIVE run can crash it). The exit code is always `0` — an empty list is not an
error, it is "safe to upgrade."

```json
{
  "schema_version": 2,
  "kind": "live_runs",
  "count": 1,
  "runs": [
    {
      "goal_ref": "goal-fresh",
      "run_id": "run-42",
      "status": "running",
      "heartbeat_age_s": 3
    }
  ],
  "first_pass_rate": { "total": 4, "first_pass": 3, "reworked": 1, "rate": 0.75 }
}
```

| Field              | Type             | Meaning |
|--------------------|------------------|---------|
| `kind`             | string           | Always `"live_runs"`. |
| `count`            | integer          | `length(runs)`. |
| `runs`             | array of objects | One entry per LIVE run, most recently started first. |
| `runs[].goal_ref`  | string           | The run's goal id. |
| `runs[].run_id`    | string           | The run registry's unique run id. |
| `runs[].status`    | string           | Always `"running"` (a terminal or stale run is excluded). |
| `runs[].heartbeat_age_s` | integer    | Seconds since the last heartbeat. |
| `first_pass_rate`  | object \| null   | The **fleet-wide** predicate first-pass rate (T68.9, #1501), pooled across every live run's goal (predicate-weighted; each distinct goal counted once). `null` when no live run has measurable iteration history. See [First-pass rate](#first-pass-rate-adr-t689-1501). |
| `schema_version`   | integer          | The contract version. |

## Run status (`kind: "run"`)

```json
{
  "schema_version": 2,
  "kind": "run",
  "ref": "cli-e2e",
  "status": "in_progress",
  "converged": false,
  "iteration": 3,
  "predicates": [
    { "id": "code", "verdict": "pass" },
    { "id": "live", "verdict": "fail" }
  ],
  "first_pass_rate": { "total": 2, "first_pass": 1, "reworked": 1, "rate": 0.5 },
  "predicate_audit": {
    "tested": 3, "constrained": 2, "survived": 1, "sensitivity": 0.6667,
    "survivors": ["weak-predicate"], "sampled_at": "2026-07-19T04:00:00.000000Z"
  },
  "release_ref": "v2026.06.24-abc1234",
  "observed_at": "2026-06-24T03:25:31.118115Z",
  "landed": [
    { "partition_id": "p-a1b2c3", "branch": "kazi/p-a1b2c3", "pr": "42", "merge_commit": "abc1234" }
  ]
}
```

| Field            | Type             | Meaning |
|------------------|------------------|---------|
| `kind`           | string           | Always `"run"`. |
| `ref`            | string           | The goal ref reported on. |
| `status`         | string (enum)    | The derived lifecycle: `converged` (the latest iteration converged) or `in_progress`. |
| `converged`      | boolean          | Whether the latest recorded iteration was judged converged (T0.8). |
| `iteration`      | integer          | The latest recorded 0-based iteration index. |
| `predicates`     | array of objects | The predicate **vector** at the latest observation — the same `{ "id", "verdict" }` shape (sorted by `id`) as `apply --json`, including the optional ADR-0041 graded fields (`score`, `prior_score`, `direction`, `evidence`) when present. See [`run-result.md`](run-result.md#predicates--graded-fields-adr-0041). |
| `first_pass_rate`| object \| null   | This goal's predicate first-pass rate (T68.9, #1501). `null` when unmeasurable. See [First-pass rate](#first-pass-rate-adr-t689-1501). |
| `predicate_audit`| object \| null   | The goal's latest sampled predicate mutation audit (T68.9, #1501): `tested`/`constrained`/`survived` counts, `sensitivity` (`constrained / tested`, a 0.0–1.0 float or `null`), the `survivors` id list, and `sampled_at`. `null` when the goal has never been audited. See [`docs/predicate-audit.md`](../predicate-audit.md). |
| `release_ref`    | string \| null   | The release ref recorded on the latest iteration (T3.3c), or `null`. |
| `observed_at`    | string (ISO 8601)| When the latest iteration's predicates were evaluated. |
| `landed`         | array of objects | **Optional** (T62.6, issue #1241). Present only when the run PERSISTED per-group landed refs — a `--parallel` run with `[integration] mode != none` that landed converged work. One entry per landed group, carrying the SAME `{branch, pr, merge_commit}` detail (T44.10 shape) the immediate `apply --parallel --json` collective output showed, so `kazi status` surfaces "what landed where" AFTER the run has exited. **Omitted entirely** for a run that landed nothing (a single-goal run, or `mode = none`), keeping the object byte-identical to the pre-T62.6 shape. |
| `landed[].partition_id` | string    | The group's stable partition id (matches the collective output's `partitions[].partition_id`). |
| `landed[].branch` | string          | The group's landing branch (present when recorded). |
| `landed[].pr`     | string          | The group's PR handle (present when recorded). |
| `landed[].merge_commit` | string    | The group's merge commit (present when recorded). |
| `schema_version` | integer          | The contract version. |

The `landed` array is a purely additive projection: `schema_version` is
**unchanged** (still `2`), since a run without landed refs emits the identical
object it did pre-T62.6.

## First-pass rate (T68.9, #1501)

The **predicate first-pass rate** is the fraction of a goal's authored
predicates that were already GREEN on the FIRST recorded observation — before
the reconcile loop did any work — versus the ones that started red and needed
predicate/plan rework to reach `:pass`. It is the single best proxy for
*just-in-time authoring quality*: a low first-pass rate means `acc:` lines were
drafted against stale context (the dispatch layer, not the grind loop, is the
weak point).

It is a pure projection over the persisted iteration history
(`Kazi.Reconcile.FirstPassRate`): a predicate is **first-pass** when it is
`:pass` in the earliest recorded `Kazi.PredicateVector` for the goal;
everything else (`:fail`/`:error`/`:unknown`) is **reworked**. No provider is
re-run.

```json
{ "total": 4, "first_pass": 3, "reworked": 1, "rate": 0.75 }
```

| Field        | Type          | Meaning |
|--------------|---------------|---------|
| `total`      | integer       | Authored predicates measured (the first vector's size). |
| `first_pass` | integer       | Green on the first observation. |
| `reworked`   | integer       | `total - first_pass` — needed loop rework. |
| `rate`       | number        | `first_pass / total`, a 0.0–1.0 float. |

The whole object is `null` when there is nothing to measure (no recorded
iterations, or an empty first vector). On the single-`<ref>` `run` surface it is
that goal's rate; on the no-`<ref>` `live_runs` surface it is the fleet-wide pool
across every live run's goal, summing numerators and denominators
(predicate-weighted, each distinct goal counted once). Additive: `schema_version`
is unchanged (still `2`). See [`docs/predicate-audit.md`](../predicate-audit.md)
for the companion mutation-audit metric.

## Proposal status (`kind: "proposal"`)

```json
{
  "schema_version": 2,
  "kind": "proposal",
  "ref": "prop-ship-a-healthz-endpoint-3f9c1a2b4d5e",
  "status": "proposed",
  "goal_id": "ship-a-healthz-endpoint",
  "idea": "ship a healthz endpoint"
}
```

| Field            | Type          | Meaning |
|------------------|---------------|---------|
| `kind`           | string        | Always `"proposal"`. |
| `ref`            | string        | The proposal ref reported on. |
| `status`         | string (enum) | The lifecycle state: `proposed`, `approved`, or `rejected`. |
| `goal_id`        | string        | The drafted goal's id. |
| `idea`           | string        | The prose idea the proposal was drafted from. |
| `schema_version` | integer       | The contract version. |

## Error object

An unknown ref emits a failure envelope on the **same** stdout stream (so the
orchestrator parses one surface and branches on the non-zero exit):

```json
{
  "schema_version": 2,
  "error": "no run or proposal found for ref \"does-not-exist\" ..."
}
```

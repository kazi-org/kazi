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

The positional `<ref>` resolves in order:

1. a **run**'s `goal_ref` (a goal id the loop has recorded iterations for) →
   `kind: "run"`, the latest iteration's state; otherwise
2. a **proposal**'s `proposal_ref` (an authoring handle) → `kind: "proposal"`, its
   lifecycle state.

An unknown ref is the error object below with a non-zero exit.

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
  "release_ref": "v2026.06.24-abc1234",
  "observed_at": "2026-06-24T03:25:31.118115Z"
}
```

| Field            | Type             | Meaning |
|------------------|------------------|---------|
| `kind`           | string           | Always `"run"`. |
| `ref`            | string           | The goal ref reported on. |
| `status`         | string (enum)    | The derived lifecycle: `converged` (the latest iteration converged) or `in_progress`. |
| `converged`      | boolean          | Whether the latest recorded iteration was judged converged (T0.8). |
| `iteration`      | integer          | The latest recorded 0-based iteration index. |
| `predicates`     | array of objects | The predicate **vector** at the latest observation — the same `{ "id", "verdict" }` shape (sorted by `id`) as `apply --json`. |
| `release_ref`    | string \| null   | The release ref recorded on the latest iteration (T3.3c), or `null`. |
| `observed_at`    | string (ISO 8601)| When the latest iteration's predicates were evaluated. |
| `schema_version` | integer          | The contract version. |

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

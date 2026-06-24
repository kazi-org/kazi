# `kazi run --parallel --json` collective result contract (schema_version 1)

The single, **versioned** JSON object `kazi run --parallel --json` emits to stdout
on termination (T21.8, ADR-0027 + ADR-0023). It is the COLLECTIVE companion to the
serial `run --json` contract (`docs/schemas/run-result.md`): where that object
reports ONE goal's loop result, this object reports the **collective verdict over a
partitioned goal-set** — the parallel scheduler's `%{collective:, partitions:}`
result rendered and versioned.

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

`schema_version` is a compatibility surface shared with the serial `run --json`
contract (one number an orchestrator pins). An additive change (a new field) leaves
it unchanged; a **breaking** change (a removed/renamed field, a changed type or
meaning) bumps it.

Current version: **1**.

## Shape

```json
{
  "schema_version": 1,
  "goal_id": "cli-parallel",
  "collective": "converged",
  "partitions": [
    {
      "partition_id": "k-a1b2c3",
      "goal_ids": ["cli-parallel"],
      "status": "converged"
    }
  ],
  "next_action": "done"
}
```

## Fields

| Field            | Type             | Meaning |
|------------------|------------------|---------|
| `schema_version` | integer          | The contract version (shared with `run-result.md`). Bumped on a breaking change. |
| `goal_id`        | string           | The goal-set's goal id — the run's handle. |
| `collective`     | string (enum)    | The COLLECTIVE verdict — one of `converged`, `stuck`, `over_budget`. The orchestrator's primary branch. |
| `partitions`     | array of objects | One entry per partition, in the scheduler's input order. A single-partition goal-set yields exactly one entry (the serial degenerate). |
| `next_action`    | string (enum)    | An orchestration **hint** derived from `collective` — `done`, `investigate`, or `raise_budget`. NOT a kazi action; the orchestrator owns the policy (ADR-0023). |

### `partitions[]`

| Field          | Type            | Meaning |
|----------------|-----------------|---------|
| `partition_id` | string          | The partition's stable lease key (`Kazi.Scheduler.Partitioner` `:key`): overlapping partitions share it, disjoint partitions differ. Falls back to `partition-<index>` for an unkeyed partition term. |
| `goal_ids`     | array of string | The ids of the `%Kazi.Goal{}` member goals this partition carries, so a partition verdict maps back to its goals. |
| `status`       | string (enum)   | This partition's terminal reconciler status — one of `converged`, `stuck`, `over_budget`, `stopped`, `crashed` (`Kazi.Scheduler.partition_status/0`). |

### `collective`

The pure fold the scheduler computes over the per-partition statuses
(`Kazi.Scheduler.collective_verdict/1`), order-independent and total:

| Value         | When |
|---------------|------|
| `converged`   | **Every** partition converged (collective success). Exit `0`. |
| `over_budget` | **Any** partition hit a hard budget ceiling — surfaced first as the most actionable "we spent the budget" signal. Exit non-zero. |
| `stuck`       | Otherwise — some partition did not converge (a stuck / stopped / crashed reconciler). Investigate. Exit non-zero. |

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

This is the SAME hint vocabulary the serial `run --json` result uses (ADR-0023),
so an orchestrator branches on `next_action` identically across the serial and
collective surfaces.

## Human surface

Without `--json`, `run --parallel` prints a legible collective block instead of
the JSON object — the overall verdict and one line per partition:

```
COLLECTIVE CONVERGED  goal=cli-parallel
partitions: 1
  [0] k-a1b2c3: converged
```

The exit code is identical on both surfaces; `--json` chooses only the shape.

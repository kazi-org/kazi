# Run-economics history: `kazi economy` (ADR-0058)

`kazi apply` persists a run's end-of-run economics onto the shared read-model
(T48.7): tokens, cached-input tokens, cost USD, dispatch count, terminal
outcome, harness/model/context tier, and the goal's shape (predicate count +
kind histogram). `kazi economy` is the pure-read query over that history —
it aggregates every FINISHED run into p50/p95 percentile groups so an
operator (or, later, the learned budget suggestions `kazi plan` and
`kazi init` will surface, T48.9) can see what a goal of a given shape
typically costs.

See [ADR-0058](adr/0058-economy-feedback-loop.md) for the full decision and
[docs/plans/E48.md](plans/E48.md) for the epic.

## Usage

```
kazi economy [--json]                     # aggregate across every goal on this read-model
kazi economy --goal <goal_ref> [--json]   # restrict to one goal's own history
```

Human output (the default) prints one line per group; `--json` emits a
single, versioned JSON object — see [the schema below](#--json-result).

## Grouping

Runs are grouped by `{goal_shape_bucket, model, harness}`:

- **`goal_shape_bucket`** — the goal's `predicate_count`, banded into `"1-3"`,
  `"4-8"`, `"9+"`, or `"unknown"` (a pre-T48.7 row, or a nil/non-positive
  count). Bands rather than the exact count: at kazi's local run volumes,
  grouping by exact predicate count leaves most groups with a sample of one,
  too thin to percentile meaningfully. This bucketing is implemented once, as
  the public `Kazi.Economy.History.goal_shape_bucket/1`, so a future
  learned-budget lookup (T48.9) buckets a drafted goal the SAME way this
  aggregate would have grouped it.
- **`model`** / **`harness`** — the run's recorded harness identity. A `nil`
  value (a pre-T46 row, or a harness that never reported an identity) groups
  as its own distinct bucket — it is never silently dropped or merged into a
  "known" group.

## Honest-unknown (ADR-0046)

`tokens` and `cost_usd` are nullable at the source (T48.7: a harness that
never reported usage persists `NULL`, never `0`). The aggregate mirrors that
discipline: unreported values are **excluded** from a metric's percentile
input, never coerced to `0`. A group where every run left a metric
unreported reports `p50: null, p95: null` for that metric — never a
fabricated zero. Each group also carries `n` (total runs) and `n_with_usage`
(runs that reported usage), so a consumer can judge how much to trust a
percentile from sample density alone.

`dispatch_count` is loop-tracked (not harness-reported) and defaults to `0`,
so it is never nil for a non-empty group. `wall_clock_s` is derived from
`finished_at - started_at`.

## Percentile method

Nearest-rank over the ascending-sorted, non-nil values: `rank = ceil(p/100 *
n)`, clamped to `[1, n]`. Simple and deterministic — local run history is
small enough that interpolation would not change the operator's decision.

## An empty read-model is an honest answer

A fresh read-model with no finished runs (or a `--goal` that has never
finished a run) reports `{"groups": []}` at exit `0` — never an error.

## `--json` result

```json
{
  "schema_version": 2,
  "goal_filter": null,
  "groups": [
    {
      "goal_shape_bucket": "1-3",
      "model": "claude-sonnet-5",
      "harness": "claude",
      "n": 4,
      "n_with_usage": 4,
      "tokens": { "p50": 12000, "p95": 41000 },
      "cost_usd": { "p50": 0.12, "p95": 0.41 },
      "dispatch_count": { "p50": 2, "p95": 5 },
      "wall_clock_s": { "p50": 88.0, "p95": 240.0 }
    }
  ]
}
```

`goal_filter` echoes the optional `--goal` (`null` means every goal on this
read-model was aggregated).

## `--rediscovery <goal>`: rediscovery-pressure report (ADR-0058 decision 3)

```
kazi economy --rediscovery <goal_ref> [--json]
```

A second, distinct view on the same command: instead of aggregating
run-end economics across goals, it reads one goal's recorded per-iteration
`tools` counters (T34.3) and folds them into a RANKED, report-only
rediscovery-pressure candidate list — which tool category (file reads /
search calls / code-graph queries) keeps recurring across dispatches instead
of falling off after the first, a signal that a stronger orientation pack or
retrieval cache could help. A goal with no recorded tool-use stream reports
`status: "unknown"` with a reason, never a fabricated empty ranking
(ADR-0046 honest-unknown).

This is advisory only: nothing here feeds back into a dispatch prompt. A
candidate becomes an actual prompt/context change only once the T48.12
benchmark gate measures a real reduction.

## The T48.12 benchmark gate: the ONLY path a variant ships

ADR-0058 decision 3 puts prompt/context changes in trust order: behavior
(`--rediscovery` above) proposes candidates; an opt-in debrief (T48.11)
records self-reported hypotheses; **neither ever ships on its own**. A
candidate orientation/context pack becomes a real dispatch-prompt change
only when this gate -- the `mix kazi.bench --variant <dir>` rig
(`Kazi.Bench.variant_arm/3`, `variant_report/1`, `render_variant_table/1`,
T48.12) -- measures it.

### Procedure

1. **Construct the candidate pack.** Take a ranked candidate from
   `kazi economy --rediscovery <goal>` and/or a debrief hypothesis (T48.11)
   and turn it into a concrete orientation/context-pack change (e.g. an
   added retrieval-cache entry, a reordered orientation section). This step
   is manual/agent-assisted -- kazi never applies a candidate automatically.
2. **Run the SAME fixture goal twice**, once with the current pack
   (`baseline`) and once with the candidate pack (`<candidate-name>`),
   recording each run's terminal `kazi apply --json` result.
3. **Table the comparison**:

   ```
   mix kazi.bench --variant <dir>
   ```

   where `<dir>` holds `<group>__<variant>.result.json` files -- `<group>`
   is any label that keeps a fair comparison together (e.g. the
   harness/model/tier under test), `<variant>` is `baseline` or the
   candidate's name. Example: `t1-sonnet__baseline.result.json` and
   `t1-sonnet__candidate-rediscovery.result.json`.
4. **Read the `Δ Tokens` / `Δ Iters` columns.** They are
   `(candidate) - (baseline)` on tokens-to-converge and
   iterations-to-convergence -- **negative means the candidate used
   fewer**, which is the reduction ADR-0058 requires.
5. **Ship only when ALL of these hold**, on the fixture set:
   - `Δ Tokens < 0` **or** `Δ Iters < 0` (a measured reduction on at least
     one headline metric);
   - the candidate's `Converged` column stays `yes` wherever the baseline
     did (no convergence-rate regression -- a cheaper run that stops
     converging is not a win, mirroring the T19.7/T36.5 "cheaper-but-WRONG
     is visible" rule);
   - a row with no matching baseline, or an unreported metric, renders
     `n/a` -- that is not a pass, it is unmeasured; run the missing
     baseline before deciding.
6. **If the gate passes**, land the candidate pack as the new default in
   the same change as the benchmark evidence (PR body links the
   `--variant` table). **If it does not**, the candidate stays a
   documented hypothesis -- nothing about the dispatch prompt changes.

Nothing in this procedure is automated end-to-end: kazi never mutates a
prompt from a rediscovery candidate, a debrief hypothesis, or a benchmark
result. The gate is a human/agent decision informed by a measured table --
exactly the ADR-0058 write-only boundary (kazi's behavior/self-report
layers observe and record; only a human-approved change to the pack itself
ships).

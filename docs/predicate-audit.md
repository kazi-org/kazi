# Predicate quality metrics (T68.9, issue #1501)

kazi converges a goal to a set of machine-checkable predicates. Two questions
about the PREDICATES themselves — not the goal — decide whether "converged" can
be trusted: were the predicates authored well, and do they actually constrain
the workspace? This page documents the two standing metrics that answer them.

Both are surfaced on `kazi status` (human and `--json`); see
[`docs/schemas/status.md`](schemas/status.md) for the exact `--json` shape.

## 1. Predicate first-pass rate

The **first-pass rate** is the fraction of a goal's authored predicates that
were already GREEN on the FIRST recorded observation — before the reconcile
loop did any work — versus the ones that started red and needed predicate/plan
rework to reach `:pass`.

It is the single best proxy for *just-in-time authoring quality*. kazi drafts a
task's `acc:` predicates at dispatch time; a low first-pass rate means those
lines were drafted against stale context (the DISPATCH layer, not the grind
loop, is the weak point — the loop is having to rescue predicates that should
have been authored greener).

- **Module:** `Kazi.Reconcile.FirstPassRate` — a pure projection over the
  persisted iteration history (`Kazi.ReadModel.iteration_history/1`). A predicate
  is *first-pass* when it is `:pass` in the earliest recorded predicate vector;
  anything else (`:fail`/`:error`/`:unknown`) is *reworked*. No provider re-runs.
- **`rate` = `first_pass / total`**, a 0.0–1.0 gradient; `nil` when there is
  nothing to measure (no iterations, or an empty first vector).
- **Surfaced per goal** on `kazi status <ref>` and **pooled fleet-wide**
  (predicate-weighted, each distinct goal counted once) on the no-ref
  `kazi status` live-runs view.

```
$ kazi status my-goal
STATUS     ref=my-goal kind=run
converged: true
iteration: 4
first-pass: 3/5 (60%) predicates green on first observation
...
```

## 2. Sampled predicate mutation audit

The red-at-t0 rule stops *vacuous* predicates (one that was never red proves
nothing), but not *gamed* ones — a predicate driven green by stubbing the value,
hard-coding a fixture, or deleting the failing path. Such a predicate stays green
even when the behavior it claims to test is sabotaged.

The **predicate mutation audit** measures exactly that. After a goal converges
(every predicate `:pass`), it re-evaluates the SAME predicate set against a
deliberately MUTATED workspace (revert the key hunk, inject a fault) and asks how
many of the converged predicates went red again:

- **`constrained`** — converged predicates that flipped to non-`:pass` under the
  mutation (the sabotage was caught). Higher is better.
- **`survived`** — converged predicates that stayed `:pass` despite the sabotage.
  A survivor is a weak or gamed predicate; the audit names them so a fixer can
  strengthen them.
- **`sensitivity`** = `constrained / tested`, a 0.0–1.0 estimate of how much the
  predicate set actually constrains the workspace. `nil` when nothing was
  converged to audit (honest-unknown, ADR-0046).

This is DISTINCT from the `:mutation` predicate provider
(`Kazi.Providers.Mutation`), which mutates the SYSTEM UNDER TEST to score a
test SUITE's strength. Here the mutation is applied to the workspace and the
PREDICATE SET is the thing being graded.

### How it runs

- **Core:** `Kazi.Audit.PredicateSensitivity` — `score/2` (baseline vs mutated
  vector) and `audit/2` (over an injected re-evaluation function). Only
  predicates that were `:pass` at convergence are audited; one absent from the
  mutated vector counts as constrained (it could not be evaluated ⇒ not a
  survivor).
- **Sampling:** the audit is expensive, so it is meant to run at a SAMPLE rate.
  `Kazi.Audit.PredicateSensitivity.should_sample?/2` is a deterministic,
  clock-free gate keyed on a stable string (e.g. the goal ref + an attempt
  counter): the same key + rate always decide the same way, so a periodic caller
  samples a reproducible ~`rate` fraction of convergences.
- **Orchestration:** `Kazi.Audit.run/3` gates on sampling, runs the audit over a
  supplied `reevaluate` function (which mutates the workspace, evaluates the
  predicate vector, and restores it), and records the score. The mutation
  STRATEGY is a caller concern — the core is pure over the injected function.
- **Standing metric:** `Kazi.ReadModel.record_predicate_audit/2` upserts one row
  per goal in the `predicate_audits` projection (last-write-wins), so the score
  is always the latest sample. `kazi status <ref>` surfaces it:

```
$ kazi status my-goal
...
audit:     sensitivity=67% (2/3 converged predicates flip under sabotage, 1 survived)
```

A survivor count above zero is a signal to strengthen those predicates before
trusting the goal's "converged" verdict.

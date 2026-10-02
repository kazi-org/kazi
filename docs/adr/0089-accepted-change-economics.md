# ADR 0089: Qualify changes and measure acceptance outside convergence

## Status

Accepted. The decision remains the design record; implementation and artifact
verification are recorded under E78/E79 in Kazi and E80 in Fanisi. E74/E76 and
E78/E79 are verified through Kazi v1.297.0; E80 is released as Fanisi v0.1.0.
Those source/release checks do not certify paid-model performance. E77's paid
comparison and its remaining unknown costs are recorded separately in the
evaluation report.

## Date

2026-09-07

## Context

Passing declared predicates does not establish independent correctness or
maintainability. Existing red-at-t0, sealing, enforcement, stuck detection and
economics mechanisms address parts of the problem. Rebuilding them would add
cost without closing the observed public-entry and accounting gaps.

## Decision

1. Keep `converged` defined by Kazi's declared vector and existing integration
   semantics. Independent review and verified landing remain distinct Fanisi
   evidence. Do not rename convergence into an unconditional quality claim.
2. Add opt-in behavioral-red qualification for change goals, using explicit
   target IDs. Preserve idempotent and guard-only semantics when absent. Preserve
   goal protections equally through files and proposals. Reuse ADR-0042/0080;
   neither goal hashes nor worktrees are an OS security boundary.
3. Mutation assurance credits targeted, explicit behavioral failures. Checker
   errors, missing results and unsuccessful fault application are inconclusive.
   Run declared faults on disposable candidates; do not mutate the user's tree
   or silently run expensive audits on every tick.
4. Preserve ADR-0056 per-rung budgets. An additional opt-in total dispatch limit
   bounds the invocation across rungs. Cross-invocation repairs belong to the
   evaluator's task lineage. Test a two-dispatch recipe before changing defaults.
5. Kazi emits run facts; Fanisi owns cross-harness accounting and independent
   acceptance. Import source-backed coordinator/reviewer effort and landing
   evidence into the existing Go ledger, with unknown values and overlap rules.
   A second Kazi acceptance database or automated model selector is unnecessary.

## Alternatives and consequences

A mandatory-red rule would break valid idempotent workflows. Automatically
equating green tests with acceptance repeats the observed failure. Unbounded
expert escalation can move spending outside the visible budget. A full mutation
platform and new coding agent would increase fixed costs before benefit is known.

This design adds a small configuration surface and explicit integration work.
Qualification and review themselves cost time; the comparison must charge them.
Defaults remain stable until matched accepted-change results justify a change.
Incomplete prices prevent a total-dollar verdict even if token counts are exact.
Execution and releases follow normal review; this planning change starts no paid
trials and changes no running harness or subscription settings.

# Delivery plan: make Kazi valuable per accepted change

## Current state (2026-10-01)

The E74/E76/E78/E79 source and release gates are complete in Kazi v1.297.0;
E80 source and release gates are complete in Fanisi v0.1.0. UC-073 and UC-074
are engineering-complete. UC-075's ledger and evaluation machinery is complete,
but the measurements do not establish all-in dollars or operational landing
outcomes. The original E77 cohort accepted 2/3 candidates in each arm; Kazi
used about 20% more known provider dollars and 52% more attempt wall time. The
resumed raised-allowance cohort accepted 2/3 direct and 1/3 Kazi candidates.
Known provider spend across coding attempts and the diagnostic was $0.13148736;
conservative unresolved reserves total $5.811, with $4.06398734 unallocated.
Some direct follow-up requests lack receipts, so that arm's cost is a lower
bound. No experimental candidate was operationally landed, leaving cost per
accepted landed change undefined. Keep the existing default policy; this
bounded study cannot rank general capability or prove general savings.

The separate source/release verification establishes implementation behavior
in pinned artifacts. It does not certify paid-model performance. E77's paid
cohorts likewise do not replace source/release checks. Detailed cohort limits
and the partial coordinator-token snapshot are recorded in
[`e77-evaluation-2026-09-08.md`](../e77-evaluation-2026-09-08.md). Private
fixtures, candidates, receipts and transcripts remain outside the public repo.

## Deliverables and use case summary

| Priority | Outcome | Owner | Plan | Effort estimate |
|---|---|---|---|---|
| 1 | Genuine behavioral-red admission, preserved protections, honest mutation audit | Kazi implementer | E78 / UC-073 | 8h |
| 2 | Run-wide allowance and compact evidence handoff | Kazi implementer | E79 / UC-074 | 5h |
| 3 | Full effort and independently reviewed landing in the ledger | Fanisi implementer | E80 / UC-075 | 7h |
| Gate | Pre-register the comparison using working artifacts | Evaluation owner | E77 / UC-075 | 90m planning, execution estimated then |

Three P0 use cases are represented by these contracts. Discovery inspected real public parsing,
runtime, seal/enforcement, stuck/budget/ladder, audit and Fanisi ledger seams.
Existing features are reused. `docs/concept.md` is the architecture reference;
there is no `docs/design.md`. ADR-0089 records the new decisions. The detailed
15 implementation rows each contain scope, dependencies, acc and regression
requirements. They are interactive contracts, not claims of cheap-model certification.

## Historical ordering and estimates

The September plan sequenced E78, E79 and E80 after checking E74/E76 residuals,
with about 20 engineering hours estimated before review, provisioning and
release. These are completed records, not current dispatch instructions. E75
remains deferred optional orientation tuning and did not block accounting or
E77. Do not infer paid-model certification from source/release completion.

This quarter: expand only the measured bottleneck. Candidate investments are
resumable jobs, stronger worker containment, context compaction and routing.
Each requires a bounded multi-task experiment; a new general-purpose coding
agent, graph platform or analytics service is outside this implementation plan.

## Candidate evaluation protocol (freeze at T77.0, not an execution order)

1. Select three unfamiliar real changes for a feasibility pilot: a behavioral
   bug, a cross-module contract change and a regression-sensitive maintenance
   change. Use concrete Sire issues only after checking current code; open issue
   status is not proof that work remains. Require runnable environment, genuine
   red baseline, a useful scoped change and independent maintainability review.
2. Freeze each base commit, task brief, verifier/toolchain fingerprint, required
   negative/generalization cases, targeted faults and allowed writes before
   worker execution. Reject weak/unrunnable evaluators before paying. Changes
   discovered during review become protocol amendments and a new cohort; do not
   silently move the bar for one arm.
3. Pair direct Claude and Kazi-driven Claude on separate worktrees of the SAME
   base. Pin OpenRouter `z-ai/glm-5.3-flash`, provider, harness binary and process
   configuration. Use the same external final evaluator and allowances. Record
   unavoidable differences in per-turn semantics. Native Fanisi remains the
   runner/accountant, not a third coding arm in the initial comparison.
4. Randomize arm order with a recorded seed. Use separate fresh coordinator
   sessions; do not reveal the other candidate or its review findings. Review
   candidates against a fixed rubric, blinded to arm where feasible. Count task
   preparation once as shared cost and treatment-specific orchestration separately.
5. Candidate pilot: three task pairs, six initial runs. Proposed per-run ceiling:
   15 minutes worker time, two dispatches total and no automatic extra repair;
   also enforce the harness's available call/token limits. A two-dispatch policy
   is a treatment hypothesis. Compare it separately from context changes; keep
   default context settings in the initial Kazi-overhead comparison.
6. Proposed paid-worker allocation for a new approved study: $5 pilot and up to
   $20 follow-up, $25 total including failed calls and diagnostics. These are
   proposed limits, not a renewed spending authorization from the completed
   five-hour session. Receipt lag prevents an exact real-time invoice guarantee:
   admit calls conservatively, stop on unresolved coverage or reserve exhaustion,
   and enforce token/time caps too. Never use an entire shared-key delta as task
   attribution. Fix instrumentation offline rather than buying more opaque runs.
7. If the pilot proves instrumentation and reveals no integrity failures,
   consider six tasks with two paired repetitions (24 initial runs), reusing
   pilot trials only if protocol-identical. Final sample size, runtime exposure
   and budget feasibility are fixed at T77.0; do not promise statistical power
   or a universal winner from a small sample.

## Acceptance, landing and decision rules

Paired runs answer cost/time per independently accepted CANDIDATE. Two alternate
patches for the same task cannot both be counted as independently shipped tasks.
Select one for normal review/landing; the other remains reviewed-unlanded.
To measure actual cost/time per LANDED change, follow with a task-level randomized
operational cohort: assign each new task one arm before work starts, stratified
by task type. Keep assisted repairs and abandoned tasks charged to their original
assignment; report autonomous and assisted outcomes separately. Do not mix the
paired and operational denominators.

Use these gates, agreed before the first run:

- Integrity failure (changed verifier, weakened tests, hidden failure omitted,
  unsupported landing identity): reject the candidate and stop that protocol
  until diagnosed. Retain its cost. A critical review defect is not offset by
  cheap calls. Record reversions or newly found defects during a seven-day
  follow-up; initial landing is a provisional outcome until that window closes.
- Report every task and attempt, accepted counts, all-attempt known spend,
  coverage, actor token/effort totals, elapsed to acceptance/landing, reviewer
  interventions and fixed tooling investment. Zero accepted tasks means undefined
  cost per acceptance. Missing dollar prices mean no total-dollar verdict.
- Retain a treatment for further testing only if independent quality is
  preserved and paired accepted outcomes show a favorable cost/time tradeoff.
  If cost falls but latency rises, report the tradeoff rather than invent a
  combined score. No default flip on the pilot; require confirmation in the
  operational cohort. Mixed or sparse evidence means keep Kazi optional.
- Include every rejected, failed, cancelled and timed-out run; bound the review
  effort as part of the protocol and report exhausted review as pending, not
  accepted. Review checks scope, unnecessary abstraction/dependencies, duplication,
  removed coverage, compatibility and readability as well as behavior.

## Verification, rollback and handoff

All new fields are opt-in/additive; legacy schema and historical records get
explicit compatibility fixtures. A source rollback leaves retained run facts
and audit history readable. Source changes use normal review and release gates,
with isolated installed-binary smoke tests; no web deployment is involved.
Actual savings are a later evaluation result, not an implementation acceptance
criterion. Cross-repository links and plan dependencies are validated locally.

The first execution handoff is T78.1: inspect the live authoring/loader surface,
claim a dedicated worktree, reproduce dropped protection fields with a fake
harness, fix the round trip and submit the small reviewed change.

## Progress Log

2026 09 07: Defined priorities, capacity, staged trial design and acceptance denominators; paid experiments deferred to the executable evaluation protocol.

2026 09 07: Implemented E78/E79 source in Kazi PR #1842 and E80 in merged Fanisi PR #5. Kazi independent review cleared; 280 targeted cases plus 34 existing prompt cases pass. Eight offline assembled-release scenarios pass on the prerebase candidate. Final CI/release gates remain open; local Burrito packaging failed at macOS linking. E74 public dispatch coverage and E76 persisted/public cost provenance remain incomplete. E77 stays dependency-gated; no paid study or active binary replacement occurred. Detailed evidence: docs/accepted-change-validation.md in PR #1842.

2026 09 07: Final source 60af75c8 assembled successfully into an isolated Mix release (embedded base version 1.295.2, schema 2) after obtaining/releasing the mini build lease. All eight offline acceptance/bounded-repair scenarios pass with private run sinks and readable SHA-verified handoff artifacts. Release workflow now gates every binary upload on this smoke; macOS x86_64 uses Rosetta. Distributed verification remains open.

2026 09 07: Kazi PR #1842 merged at f681a446fbf88471cac329e823bd24c75981c9c2 after independent review and all nine required checks passed. Final disposable CI: 5,038 passed (234 doctests, 4,804 tests), 124 excluded. Source implementation rows are complete; distributed-release rows remain open, alongside the recorded E74/E76/E77 dependencies.

2026 09 07: E74 source/public/installed contract complete in [Kazi PR #1844](https://github.com/kazi-org/kazi/pull/1844) and downloaded Kazi v1.296.1 (12 offline scenarios); E78/E79 downloaded v1.296.0 verification complete. E80 is released as Fanisi v0.1.0 with 18 offline distributed checks and 90 race-enabled source cases. E76 source merged in [Kazi PR #1846](https://github.com/kazi-org/kazi/pull/1846) after 5,063 CI cases and 16 isolated candidate scenarios; its distributed smoke remains pending. No paid evaluation started. E77 preliminary screening excludes Sire #825/#845 as already implemented and retains three candidate shapes for baseline validation, not a frozen cohort.

2026 09 07: Kazi v1.297.0 downloaded-native verification completed: all 16 offline scenarios pass, with the published checksum verified. E74/E76/E78/E79/E80 release gates are complete; public evidence is consolidated in merged [Kazi PR #1848](https://github.com/kazi-org/kazi/pull/1848). E77 is now an executable offline frontier: private evaluator/regression qualification, a matched Fanisi/Kazi Attempt adapter (merged Fanisi PR #8, release pending), and explicit provider-request admission before final preregistration. Paid execution remains blocked on fresh study-specific approval.

2026 09 07: E77 offline delivery is frozen. Fanisi v0.1.2 (source `cbcd838872b2a43d9316eafac70a0027217e5919`, downloaded SHA-256 `f76fd9f42fd111f893feade7ca82c22fdebb3f757ac12307915e664fbaf6ac0e`) passed its published archive, ledger and installed admission checks. The private bundle records 31 exact evaluator controls, 28 named contract tests and six downloaded task/arm reference controls; all are bound to pinned Kazi v1.297.0, Fanisi v0.1.2, Claude 2.1.263, Go and compiler identities. Frozen manifest SHA-256 is `6f064aca2fc07c0782366d62efc47dcc80696e04d9f58433acdf83ed6fd6bdb1`. No paid provider request, autonomous candidate or Sire landing occurred. T77.3 remains blocked pending explicit study-specific human approval naming this manifest and the $5 reserve; no approval is implied by the overnight handoff.

2026 10 01 reconciliation of final 2026 09 08 E77 resumed completion: the registered raised-allowance follow-up accepted 2/3 direct candidates and 1/3 Kazi candidates. Across the completed cohorts and diagnostic, known provider spend is $0.13148736; unresolved conservative reserves are $5.811 and unallocated allowance is $4.06398734. The direct follow-up cost remains a lower bound because some requests lack receipts. The partial coordinator export observed 24,717,036 input tokens (24,323,328 cached) and 101,080 output tokens through 2026-09-08T09:49:00.951Z; it is not a complete session total and coordinator dollars remain unknown. No candidate was operationally landed, so cost per landed change is undefined and the seven-day follow-up did not begin. No default-policy change follows. See the [evaluation report](../e77-evaluation-2026-09-08.md) for the accounting boundaries.

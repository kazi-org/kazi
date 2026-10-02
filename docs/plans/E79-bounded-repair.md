# E79 -- Bound unsuccessful repair and preserve a useful handoff

This is a completed engineering delivery record. Checked task contracts and
milestone logs preserve verification evidence, not a new assignment queue.
Additional work follows the [current roadmap](../roadmap.md).


Final status (2026-10-01): E79 implementation and release verification are
complete in the Kazi v1.297.0 consolidated downloaded-artifact suite
([PR #1848](https://github.com/kazi-org/kazi/pull/1848)). UC-074 is
engineering-complete. This source/release evidence does not certify paid-model
performance.
fidelity: executable
Acceptance: An opt-in total run allowance cannot be reset by escalation, failed calls count, and a stopped run returns a bounded, reproducible handoff without losing the task contract.

## Context and use case

UC-074 (P0, engineering COMPLETE): stop paying for repeated failure and resume from evidence.
Kazi already has `max_dispatches`, scored stuck detection, an attempt ledger and
a 12,000-byte default stuck bundle. Its ladder deliberately resets per-rung
budgets. Do not build another retry controller or infer semantic progress from
changed filenames. See ADR-0061, ADR-0045 and ADR-0089.

## Checkable work breakdown

### Wave 1: Total allowance (1 agent)

- [x] T79.1 Add an opt-in run-wide dispatch ceiling. Owner: pool Est: 90m lane: agent verifies: [UC-074] deps: [] acc: [With budget.max_total_dispatches set to two, a fake harness is launched at most twice across all declared ladder rungs, including failed launches.]  Done: 2026-09-07 (final source merge, PR #1842)
  - Scope: `lib/kazi/budget.ex`, `lib/kazi/goal/loader.ex`, `lib/kazi/authoring.ex`, `lib/kazi/loop/budget.ex`, `lib/kazi/loop.ex`, `lib/kazi/loop/ladder.ex`; budget/loader/authoring/ladder tests. Preserve the new budget field through proposal persistence too. Contract: `docs/tasks/T79.1.md`.
  - This proposed field is additional to per-rung max_dispatches. Absent means unchanged behavior. Check the cumulative counter before launching, preserve it across rung changes, and expose the stopping dimension. Observation ticks do not consume dispatch allowance. A worker timeout or error does; verification after the last allowed dispatch still runs and may converge.
  - A separate apply invocation is a separate run; cross-run repair allowance belongs to Fanisi lineage. Never claim this bounds hidden model calls inside the harness. Keep provider/model pinning independent; no Anthropic model escalation for this study.

### Wave 2: Evidence for the next repair (1 agent)

- [x] T79.2 Extend the existing stuck bundle with reproducible attempt identity. Owner: pool Est: 90m lane: agent verifies: [UC-074] deps: [T79.1] acc: [A stopped run reports base/candidate identity, total dispatches, stop reason, failing IDs, verification refs and the complete contract reference within its configured bundle byte limit.]  Done: 2026-09-07 (final source merge, PR #1842)
  - Scope: `lib/kazi/context/stuck_bundle.ex`, `lib/kazi/memory/attempt_ledger.ex`, `lib/kazi/loop.ex`, related tests. Reuse artifact storage/redaction; no second transcript database.
  - Keep mandatory task text in its immutable artifact; the bounded bundle links to it rather than truncating requirements. Include measured patch identity, verification changes and repeated-attempt fingerprints. Mark absent workspace/evidence unknown. Touched files alone do not establish progress. Preserve no-progress, graded-improvement, transient-live and quarantine behavior.
  - Test long multibyte diagnostics, missing artifacts, repeated attempts, changed patch with unchanged failures, secret redaction and deterministic byte bounds. An inaccessible reference must be diagnosed, not presented as a usable handoff.

### Wave 3: Test the policy through real entry points (1 agent)

- [x] T79.3 Add an opt-in one-attempt-plus-one-repair recipe. Owner: pool Est: 60m lane: agent verifies: [UC-074] deps: [T79.2] acc: [A synthetic stalled task stops after two launches and its public JSON handoff supports a fresh-session repair without re-reading the original transcript.]  Done: 2026-09-07 (final source merge, PR #1842)
  - Scope: `docs/orchestrator-recipe.md`, new `test/kazi/cli/bounded_repair_test.exs`, existing `test/kazi/loop/escalation_ladder_test.exs` and stuck-bundle tests.
  - Exercise goal-file and approved-proposal paths; validate field propagation, check-only behavior, and the legacy no-field case. Cover a successful second attempt, two failures, setup failure, observation-only ticks, and a ladder that would otherwise renew the budget.
  - This is an experimental recipe, not a default flip. Human/agent escalation means a compact handoff; do not automatically buy an expert model or start an outer retry loop. Repeated semantic mistakes identified by review require an amended brief or focused repair, not another invisible retry.

- [x] T79.4 Validate and ship bounded repair. Owner: pool Est: 60m lane: agent verifies: [UC-074, infrastructure] deps: [T79.3] acc: [Source and isolated installed-CLI fixtures confirm the two-launch ceiling and complete handoff, and the released version repeats the fixture.]  Done: 2026-09-07 (final downloaded-artifact gate, Kazi v1.296.0)
  - Run `MIX_ENV=test TEST_SERVER=false mix test test/kazi/loop/budget_test.exs test/kazi/loop/escalation_ladder_test.exs test/kazi/loop/stuck_detector_test.exs test/kazi/loop/stuck_bundle_test.exs test/kazi/context/stuck_bundle_test.exs test/kazi/memory/attempt_ledger_test.exs test/kazi/cli/bounded_repair_test.exs`; include any new loader/budget cases. Formatter, compile warnings, diff check and normal isolated CI are required.
  - Follow E78's isolated install, review and distributed-release smoke. Record actual launch counts and deliberately disable the ceiling once to show the fixture detects a third launch.

## Timeline and risks

Estimated effort: 5 hours plus review/release. One implementer; serialize loop
changes with E74/E75/E76/E78. Begin after the first acceptance corrections; no
dependency on optional orientation tuning. A low ceiling may reduce successful
completion on hard tasks: evaluate it separately before adoption. Runtime limits,
provider receipts and cross-run lineage remain distinct accounting concepts.

## Historical delivery evidence

2026 09 07: Planned four executable slices reusing existing retry and handoff machinery; defaults unchanged.

2026 09 07: T79.1–T79.3 implemented and independently reviewed in PR #1842. Tests cover a cumulative two-launch limit across escalation, final convergence/integration and immutable contract/evidence handoff. The isolated prerebase assembled candidate passed four public bounded-repair scenarios. T79.4 remains open pending final CI/merged distributed-artifact smoke.

2026 09 07: Final source 60af75c8 assembled successfully into an isolated Mix release (embedded base version 1.295.2, schema 2) after obtaining/releasing the mini build lease. All eight offline acceptance/bounded-repair scenarios pass with private run sinks and readable SHA-verified handoff artifacts. Release workflow now gates every binary upload on this smoke; macOS x86_64 uses Rosetta. Distributed verification remains open.

2026 09 07: Kazi PR #1842 merged at f681a446fbf88471cac329e823bd24c75981c9c2 after independent review and all nine required checks passed. Final disposable CI: 5,038 passed (234 doctests, 4,804 tests), 124 excluded. Source implementation rows are complete; distributed-release rows remain open, alongside the recorded E74/E76/E77 dependencies.

2026 09 07: Downloaded v1.296.0 macOS arm64 asset, verified published SHA-256 5d49a7a990e755b87c1ac06c0e34fa8f721129da5d621645715312205cdb1e3d, and passed all eight offline public acceptance/bounded-repair scenarios (schema 2). Release workflow 34112673298 passed all four artifact builds with pre-upload smoke. Distributed gate closed; active installation unchanged.

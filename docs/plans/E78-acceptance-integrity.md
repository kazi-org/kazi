# E78 -- Qualify acceptance before paying for changes

This is a completed engineering delivery record. Checked task contracts and
milestone logs preserve verification evidence, not a new assignment queue.
Additional work follows the [current roadmap](../roadmap.md).


Final status (2026-10-01): E78 implementation and release verification are
complete in the Kazi v1.297.0 consolidated downloaded-artifact suite
([PR #1848](https://github.com/kazi-org/kazi/pull/1848)). UC-073 is
engineering-complete. The dated open-gate notes below are historical and
superseded by the final release record. No paid-model certification is implied.
fidelity: executable
Acceptance: An opted-in change goal requires a genuine behavioral failure, preserves its verification protections through public entry points, and cannot earn mutation credit from a broken checker.

## Context

This was the first priority in the 2026-09-07 accepted-change improvement plan.
The initial bounded engineering study, reported 2026-09-07, produced zero
autonomous accepted tasks; verifier-green candidates failed independent review,
and one task landed after coordinator repair. The later E77 comparison has its
own completed results in the evaluation report. These observations justify
stronger qualification without ranking general model or Kazi capability.

Existing mechanisms: `runtime.ex` rejects an entirely green t0 vector;
`seal.ex` detects protected-input changes; enforcement supports clean-tree
grading; held-out checks are omitted from dispatch; mutation providers exist.
The gaps are narrower: errors/unknown or landing-only failures can admit an
already-solved task; proposal authoring drops protection fields; sensitivity
scoring credits non-pass errors and missing results. `Kazi.Audit.run/3` has no
production caller found in this discovery. See ADR-0089.

Use cases: UC-073 (P0, engineering COMPLETE): qualify a real behavioral change and preserve
the independent grading contract. Existing UC-069 remains valid for idempotent
and guard-only goals. No global requirement that every maintenance run be red.

## Checkable work breakdown

### Wave 1: Correct existing boundaries (1 agent, two serial tasks)

- [x] T78.1 Preserve protection settings through proposal authoring. Owner: pool Est: 90m lane: agent verifies: [UC-073] deps: [] acc: [An approved proposal round-trips held_out, seal and enforcement settings and rejects malformed settings before any harness launch.]  Done: 2026-09-07 (final source merge, PR #1842)
  - Scope: `lib/kazi/authoring.ex`, reuse `lib/kazi/goal/loader.ex` parsers; `test/kazi/authoring_test.exs`, `test/kazi/cli_apply_proposal_ref_test.exs`.
  - Cover omitted defaults, true/false held_out, seal file lists, enforcement configuration, unknown/malformed values, persistence and reload. Serialize the fields as well as parsing them. Keep integration behavior unchanged. Do not copy parser logic into a second schema.
  - Paired boundary test: actual plan/approve/apply with a fake executable captures no hidden sentinel; editing a sealed input yields tampered, not convergence. Repeat with a direct goal file. Restoring either dropped field must fail its regression.

- [x] T78.2 Distinguish mutation detection from checker failure. Owner: pool Est: 60m lane: agent verifies: [UC-073] deps: [] acc: [Mutation scoring counts only explicit targeted fail verdicts as detected faults; missing, error and unknown results remain inconclusive.]  Done: 2026-09-07 (final source merge, PR #1842)
  - Scope: `lib/kazi/audit/predicate_sensitivity.ex`, `lib/kazi/audit.ex`, `lib/kazi/read_model/predicate_audit.ex`, their existing tests. Contract: `docs/tasks/T78.2.md`.
  - Record eligible, detected, survived and inconclusive counts with targeted IDs. Unrelated passing guards are not survivors. An empty eligible set has null sensitivity. Preserve historical records as legacy coverage, never reinterpret old scores as stronger evidence.
  - Paired tests include dropped ID, timeout/error, unknown, explicit failure, unrelated guard and empty target set. Accounted counts must reconcile. A failing build is inconclusive unless a separately declared compile-behavior target demonstrably exercised its intended assertion.

### Wave 2: Qualify the change (1 agent)

- [x] T78.3 Add opt-in behavioral-red admission. Owner: pool Est: 90m lane: agent verifies: [UC-073, UC-069] deps: [T78.1] acc: [A goal with qualification.required_red predicate IDs dispatches only after those IDs have explicit baseline fail verdicts; green, unknown, errors and landing-only failures launch no worker.]  Done: 2026-09-07 (final source merge, PR #1842)
  - Proposed surface, not implemented: `[qualification] required_red = ["behavior"]`. Reuse goal/proposal parsing and validation; reject missing IDs, guard/landed targets and empty explicitly supplied lists. Absent block preserves current semantics.
  - Scope: `lib/kazi/goal.ex`, `lib/kazi/goal/loader.ex`, `lib/kazi/authoring.ex`, `lib/kazi/runtime.ex`, runtime/loader/proposal tests. Run setup before qualification. Require all declared required-red IDs to fail; a broken environment is an environment error, not a product failure.
  - Persist baseline commit or explicit non-git identity, evaluator fingerprint, selected IDs, verdicts and evidence refs in the existing run record. Missing provenance stays explicit. No provider call or paid drafting during validation. Check-only runs and guard-only goals retain their documented behavior when not opted in.

- [x] T78.4 Run a declared mutation against a disposable candidate. Owner: pool Est: 90m lane: agent verifies: [UC-073] deps: [T78.2] acc: [One declared fault on a passing candidate produces a targeted failure through the real provider boundary, while invalid fault application or checker errors produce inconclusive evidence and leave the candidate unchanged.]  Done: 2026-09-07 (final source merge, PR #1842)
  - Scope: extend `lib/kazi/audit.ex`, proposed `lib/kazi/audit/workspace.ex`, existing audit tests plus disposable-repository integration tests. Reuse workspace/provider APIs and existing mutation provider where suitable; no automatic fault-generation model.
  - Provide an explicit callable audit runner taking candidate ref, frozen verifier, target IDs, fault patch and timeout. Materialize a separate worktree; prove baseline pass before fault, successful fault application, targeted fail after fault, and cleanup on success/error/timeout. Never reset or mutate the caller's checkout.
  - Fanisi's evaluator may call this opt-in runner in E80. Do not insert expensive full-suite mutation into every observation, or imply production wiring until an entry-point test exercises it.

### Wave 3: Public verification and release gate (1 agent)

- [x] T78.5 Prove acceptance protections together at the public boundary. Owner: pool Est: 90m lane: agent verifies: [UC-073] deps: [T78.1, T78.2, T78.3, T78.4] acc: [Real goal-file and approved-proposal executions accept a legitimate synthetic repair and reject checker edits, blanket-success stubs and unsupported baseline failures without a paid model.]  Done: 2026-09-07 (final source merge, PR #1842)
  - Scope: new `test/kazi/cli/acceptance_integrity_test.exs`, reuse existing fake-harness support; `docs/orchestrator-recipe.md` and qualification documentation.
  - Freeze a minimal source/test fixture with positive and negative behavior. Independently sabotage its verifier with constant-success and constant-failure scripts; require the predicted failures. Assert executed case counts, hidden/quarantined sentinel absence, seal failure, and degraded isolation reporting. A hash check is tamper detection, not OS isolation or secrecy from Bash.

- [x] T78.6 Validate and ship the acceptance slice. Owner: pool Est: 60m lane: agent verifies: [UC-073, infrastructure] deps: [T78.5] acc: [The isolated installed candidate passes the public acceptance fixture and source tests, and its merged release repeats that fixture with recorded version and executed counts.]  Done: 2026-09-07 (final downloaded-artifact gate, Kazi v1.296.0)
  - Run `MIX_ENV=test TEST_SERVER=false mix test test/kazi/authoring_test.exs test/kazi/cli_apply_proposal_ref_test.exs test/kazi/runtime_test.exs test/kazi/sealed_predicate_tamper_test.exs test/kazi/audit_test.exs test/kazi/audit/predicate_sensitivity_test.exs test/kazi/read_model/predicate_audit_test.exs test/kazi/cli/acceptance_integrity_test.exs`.
  - Run formatter, warnings-as-errors compilation and diff checks; normal full CI in its disposable environment. Build/install to a separate prefix using the release procedure; never replace the active binary or subscription configuration. Review and land through normal repository gates. Release smoke is required before claiming distributed availability; source merge alone is not that evidence.

## Timeline, risks and operating procedure

Estimated effort: 8 hours plus review/release latency. First useful deliverable is
T78.1 or T78.2, each independently reviewable. Claims and fresh task worktrees are
required at execution. Serialize authoring/runtime/loop edits with E74/E79.
E80's Fanisi-only schema work can proceed independently with at most one second
implementer. All rows are interactive agent work, not certified cheap-tier jobs.

Mutation faults can test the wrong property: name the targeted behavior and
expected failure, and preserve the independent review. Qualification can reject
valid idempotent goals: keep it opt-in. Existing proposal consumers need additive
schema tests. Maintainability is reviewed for scope, duplication, abstractions,
dependency changes and removed tests; a test count alone is insufficient.

## Historical delivery evidence

2026 09 07: Added six executable acceptance-integrity rows; no implementation or certification claimed.

2026 09 07: T78.1–T78.5 implemented and independently reviewed in PR #1842. Public source fixtures cover file/proposal admission, held-out/sealed protection, blanket success and command-error refusal; disposable audit checks include tampering and timeout cleanup. T78.6 remains open pending final CI/merged distributed-artifact smoke. The isolated prerebase assembled candidate passed four acceptance scenarios; single-file packaging failed at macOS linking.

2026 09 07: Final source 60af75c8 assembled successfully into an isolated Mix release (embedded base version 1.295.2, schema 2) after obtaining/releasing the mini build lease. All eight offline acceptance/bounded-repair scenarios pass with private run sinks and readable SHA-verified handoff artifacts. Release workflow now gates every binary upload on this smoke; macOS x86_64 uses Rosetta. Distributed verification remains open.

2026 09 07: Kazi PR #1842 merged at f681a446fbf88471cac329e823bd24c75981c9c2 after independent review and all nine required checks passed. Final disposable CI: 5,038 passed (234 doctests, 4,804 tests), 124 excluded. Source implementation rows are complete; distributed-release rows remain open, alongside the recorded E74/E76/E77 dependencies.

2026 09 07: Downloaded v1.296.0 macOS arm64 asset, verified published SHA-256 5d49a7a990e755b87c1ac06c0e34fa8f721129da5d621645715312205cdb1e3d, and passed all eight offline public acceptance/bounded-repair scenarios (schema 2). Release workflow 34112673298 passed all four artifact builds with pre-upload smoke. Distributed gate closed; active installation unchanged.

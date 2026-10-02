# E80 -- Attribute total effort to independently accepted changes

Final status (2026-10-01): E80 source and distributed release verification are
complete in Fanisi v0.1.0 ([Fanisi PR #5](https://github.com/kazi-org/fanisi/pull/5)). UC-075's ledger engineering is complete; the E77
measurements still have incomplete receipt coverage and no operational landings,
so all-in cost and cost per landed change remain unknown/undefined. This
implementation evidence is separate from paid-model certification.
fidelity: executable
Acceptance: Fanisi reports reviewed and landed task outcomes alongside all attributable attempts, coordinator/reviewer effort and uncertainty, without double-counting receipts, repairs or overlapping time.

## Context and use case

UC-075 (P0, engineering COMPLETE; measured outcome PARTIAL): determine whether
adding Kazi improves accepted-change economics. Fanisi already provides `eval`, `review`, `report`, `reconcile` and
`coordinator-usage`. Review is bound to a patch; merge evidence and coordinator
data remain separate. Extend that Go tool, not a new Kazi analytics service.
Cross-repository paths below are relative to Kazi. See ADR-0089 and E77.

## Checkable work breakdown

### Wave 1: Import full effort (1 agent)

- [x] T80.1 Define and validate attributable effort records. Owner: pool Est: 90m lane: agent verifies: [UC-075] deps: [] acc: [The Go ledger accepts explicit coordinator/reviewer records tied to attempts and rejects duplicate, overlapping or inconsistent attribution without turning unknown cost into zero.]
  - Scope: `../fanisi/ledger.go`, `../fanisi/coordinator.go`, proposed `../fanisi/effort.go`, corresponding tests and `../fanisi/docs/evaluation.md`.
  - Version additive records with study/task/attempt identity, role, source fingerprint, time window, input/cached/output/reasoning subsets, known dollars or null, coverage and allocation method. Ingest existing coordinator-usage JSON rather than reparsing transcripts in the ledger.
  - Overlapping source intervals cannot both be fully attributed. Shared preparation stays a separately reported study cost unless an explicit allocation rule assigns it. Keep measured tokens, estimates and money distinct. Import offline files; no new required provider API or guessed price table.

- [x] T80.2 Expose effort ingestion through the actual CLI and report. Owner: pool Est: 90m lane: agent verifies: [UC-075] deps: [T80.1] acc: [A CLI-imported coordinator record and external review duration appear in fanisi report once after reload, with missing prices and missing review measurements explicitly unknown.]
  - Scope: Fanisi's existing CLI entry point, `ledger.go`, `effort.go` and CLI/ledger tests. Inspect live CLI before choosing final verb names; use Go standard library and existing parsing conventions.
  - Test repeated idempotent import, conflicting identity, malformed JSON, partial receipts, historical attempts, failed attempts and repair lineage. Receipt provider-plus-generation identity deduplicates the same request; the corresponding harness estimate is never added to settled cost.

### Wave 2: Bind outcomes to reviewed content (1 agent)

- [x] T80.3 Record landing evidence independently of review. Owner: pool Est: 90m lane: agent verifies: [UC-075] deps: [T80.1] acc: [A reviewed candidate counts as landed only when its reviewed content is verified against the recorded merge result; an open PR, changed patch or duplicate repair cannot increase accepted-task count.]
  - Scope: `../fanisi/ledger.go`, proposed `../fanisi/landing.go`, their tests and evaluation docs. Contract: `docs/tasks/T80.3.md`.
  - Retain separate verified/reviewed/landed dimensions and reviewer kind. Bind repo, task lineage, reviewed base/candidate, review evidence and merge commit. Support rebase/squash by verifying the scoped content delta against the target base; if intervening changes make equivalence ambiguous, require re-verification/review and report pending rather than guess from commit ancestry.
  - Use offline captured Git/GitHub fixtures and local temporary repos. Optional live lookup is read-only; this task does not merge PRs. Corrections/revocations append evidence, preserving history. Define benchmark acceptance as independent acceptance plus verified landing. A regression follow-up for the same task is not a new benchmark success.

- [x] T80.4 Produce an end-to-end comparison report. Owner: pool Est: 90m lane: agent verifies: [UC-075] deps: [T80.2, T80.3] acc: [A synthetic study with failures, assisted repair and overlapping work reports exact known spend, unknown total cost, one assisted accepted task and undefined cost per autonomous accepted task.]
  - Scope: `../fanisi/ledger.go`, `ledger_test.go`, evaluation docs. Add actor-role totals, provider coverage, accepted counts by autonomous/assisted, verified-pending counts and all attempts. Input includes cached tokens; reasoning is already part of output. Never sum those subsets twice.
  - Report request-to-verified-landing elapsed separately from active work time and summed agent effort. Overlapping intervals are not added to elapsed. Include preparation, review and CI wait, or explicit missing fields. Study tooling investment is a separate fixed cost with any amortization assumption shown.
  - With zero accepted tasks, the ratio is null/undefined. With incomplete dollar coverage, report known-cost lower bounds and decline a total-dollar savings claim. No overall model leaderboard from unmatched trials.

### Wave 3: Verify the measurement product (1 agent)

- [x] T80.5 Validate and ship the Go accounting path. Owner: pool Est: 60m lane: agent verifies: [UC-075, infrastructure] deps: [T80.4] acc: [A freshly built installed Fanisi CLI reproduces the offline study report from source artifacts and passes independent arithmetic and landing-identity checks.]
  - Run `go test -race ./...`, `go vet ./...`, `gofmt -l .`, and `git diff --check` from Fanisi; fixture subprocesses exercise real commands, not only helper functions. Build to a temporary path and run import/report there. Preserve Linux/macOS CI.
  - Deliberately duplicate a receipt, count reasoning twice, change landed content and drop a failed attempt; each mutation must trigger the predicted regression. Have an independent reviewer check arithmetic and outcome definitions. Land normal reviewed commits; document actual installed version. No service deployment or paid inference required.

## Timeline, integration and risks

Estimated effort: 7 hours plus review. One Fanisi implementer can run beside one
Kazi implementer; T80.2 and T80.3 are serial because ledger/CLI files overlap.
Use Fanisi's own claims and task worktree at execution. E76 remains the owner of
Kazi's native accounting provenance; consume its available version honestly and
do not block the offline Fanisi ledger on optional orientation changes.

Missing coordinator pricing may prevent a dollar verdict even after correct
integration. Report that limit. External reviewer work is measured or unknown,
never free by assumption. Private transcripts and provider IDs stay in ignored
artifacts; commit synthetic fixtures only. Each implementation task includes its
regression tests; no general agent framework, new dependencies or dashboard.

## Progress Log

2026 09 07: Added five executable Fanisi integration rows; accounting utilities already shipped are reused.

2026 09 07: E80 source landed in Fanisi PR #5 at 1dd4ca87044b2c984b222875ffb95ab8760aa64a after independent review and all four Linux/macOS CI checks. Verified 90 race-enabled tests, vet, formatting, five intentional mutations and isolated offline duplicate-import/report smoke. Active binary untouched; distributed-release verification remains open. See Fanisi docs/e80-validation.md.

### Distributed verification — 2026-09-07

Fanisi v0.1.0 published from `c1a02c215f53b4b8f6301dfc5ae45d4ebc9fee68` after PR #6. All four release archives were downloaded and checksummed; the native macOS arm64 binary passed 18 offline ledger checks. Its archive SHA-256 is `76fb8b018c0e9952d4eb9a8e754d5429f00c58161d18cbd288f47f52caf6d458`. The race suite executed 90 cases; Linux/macOS CI and tag CI passed. Durable evidence is Fanisi `docs/e80-release-validation.md` (PR #7, merged `67fa4181d900e1f51c8ac63c85671a6ece303bf5`). No active installation changed.

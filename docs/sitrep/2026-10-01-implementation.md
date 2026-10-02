# October 1 triage implementation

Status: implemented on `task/triage-20261001`; [PR #1859](https://github.com/kazi-org/kazi/pull/1859) is open for review and CI.
Source qualification is distinct from a release or installed-binary upgrade.

## Implemented

- Reconciled E74–E80 documentation with recorded delivery and evaluation
  evidence; indexed ADR-0089 and supplied referenced contracts. UC-073/074
  engineering scope is delivered; UC-075 all-in economics and operational
  landing outcomes remain incomplete. E75 remains optional and deferred.
- Completed T70.8 with pinned Vitest 2.1.9 multi-spec fixtures and the real
  CustomScript provider. Exact-target output matching and exit-zero both
  must hold. Negative controls cover target failure, selected sibling
  failure, and replacement of the exact target.
- Ported the smaller help-parity experiment to the current registry. Human
  usage documents registered long flags; token-boundary and removed-flag
  controls catch omissions. Runtime parsing is unchanged.
- Ported useful stuck/budget LiveView coverage to current MissionControl IDs.
  Tests isolate remote facts and session liveness. Removing the wedged-error
  attention cause makes the regression fail. The optional tier hint is deferred.
- Kept external predicate-tool flags out of the Kazi CLI coherence check while
  retaining checks for Kazi invocations.
- Ignored the local project channel in this public repository.

## Verification

Focused verification passed: 67 UI/help tests, then 25 Vitest/coherence tests.
Help and attention-cause mutation controls failed as expected and passed after
restoration. Formatting, whitespace, public-content leak, attribution,
docs-with-code and documented-command checks passed.

The corrected broad local run passed 5,065 tests and doctests with 124 exclusions.
The initial run was invalidated by a temporary directory inside Git and Unix
socket path length; a Git fixture also inherited the parent repository and
opened a PR with test-generated metadata. The PR was retained for this
implementation and its title/body corrected. The rerun used a short SSD
directory outside Git. Final coherence verification passed 24 tests, including
Mix-wrapper and mixed-shell regression cases.
The local macOS daemon-reregister module assumes no installed LaunchAgent;
this host has one, so it is excluded from the local rerun and retained
unchanged for Linux CI. No host configuration was removed or reconfigured.
Historical documentation-freshness advisories remain outside this triage.

## Preserved and deferred

Original checkouts, the unfinished T70.8 worktree, branch references and authored
local drafts are preserved. Media, the planning RFC, generic external-executor
proposal, private handoff material, branch cleanup and optional UI changes are
excluded. The 102-tip/490-branch inventory remains a review disposition,
not authorization to delete refs. No paid evaluation or production deployment
is required to qualify these changes.

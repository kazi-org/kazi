# Accepted-change delivery evidence

The E74/E76/E78/E79 release gates are complete in Kazi v1.297.0. The
downloaded native artifact passed 16 offline scenarios. Fanisi v0.1.0 completes
the E80 ledger gate. E77 remains offline preparation; no paid comparison or
productivity verdict is implied.

Source implementation: [Kazi PR #1842](https://github.com/kazi-org/kazi/pull/1842).
Ledger implementation: [Fanisi PR #5](https://github.com/kazi-org/fanisi/pull/5),
merged as `1dd4ca87044b2c984b222875ffb95ab8760aa64a`.

## Source checks (2026-09-07)

The Kazi E78/E79 suite executed 209 cases (13 doctests, 196 tests). After
rebasing onto `9daf6804`, the same suite plus the existing Claude adapter and
usage suites executed 280 cases (13 doctests, 267 tests), all passing. Existing
brief, process-contract, orientation and prompt suites separately passed 34
cases (4 doctests, 30 tests). Formatting and strict compilation were checked.
The broad daemon suite runs in disposable CI; it was not run against the host.

Independent read-only review cleared the implementation and separately cleared
its integration with the already merged complete-contract and usage fixes.
Intentional mutations disabling the cumulative ceiling and crediting every
non-pass audit result each failed the corresponding regression. Public fixtures
also reject blanket-success repairs, ambiguous command failures, checker
modification and missing evidence. These are correctness checks, not evidence
of model productivity or savings.

Fanisi executed 90 race-enabled Go tests, vet, formatting, five intentional
mutations and an isolated offline duplicate-import/report smoke. Its
`docs/e80-validation.md` records the ledger evidence and limitations.

## Isolated artifact checks

An assembled Mix release candidate reporting version `1.295.0` and schema 2
passed eight offline public CLI scenarios: file and approved-proposal paths,
second-launch success and two-launch exhaustion, genuine behavioral repair and
blanket-success rejection. The version is the candidate's embedded base version,
not a claim that those changes shipped in that public version. This artifact
predates the final rebase; it does not certify the final merged artifact.

The reproducible harness is `test/support/accepted_change_release_smoke.py`.
Pass an isolated binary path, or an assembled release's `bin/kazi` path followed
by `--mix-release`. It prepends a fake Claude executable, uses private temporary
state, performs no paid inference, and asserts schema outcomes, launch counts
and readable handoff references. The behavior checker executes three assertions.
Temporary evidence is retained for diagnosis. The release workflow runs this
smoke before artifact upload on every supported release target.

The final smoke revision isolates run sinks with `KAZI_SINKS_DIR` (and an
explicit app configuration for older assembled releases), asserts schema 2 and
reads/hash-checks both handoff artifacts under the temporary root. All eight
scenarios passed with those stronger checks. A runtime configuration check
confirmed the new sink override.

Disposable CI on the rebased implementation passed 5,038 cases (234 doctests,
4,804 tests), with 124 excluded. A later run exposed an existing heartbeat-test
struct-order comparison across a minute boundary; the assertion now uses
`DateTime.compare/2`, and all five heartbeat tests pass. The final merge gate subsequently passed; the distributed checks below record
the released artifacts.

Single-file Burrito packaging failed locally: the host Zig version was
incompatible, and retrying with the repository-pinned Zig 0.15.2 failed linking
macOS system symbols. At that stage the assembled release worked and the distributed check remained
open. The released artifacts below subsequently passed their checks. No active
installation or subscription configuration changed.

## Evaluation gate

E74, E76, E78, E79 and E80 are implemented and have passed their release checks.
The dated sections below distinguish source, assembled candidate and downloaded
artifact evidence. Local packaging failure was not treated as a passing release
check; the distributed gates closed only after the published artifacts ran.

E77 is qualifying candidate task evaluators and its runner offline; final
freezing remains pending. No new
paid comparison has run, no proposed budget is spending authorization, and no
productivity claim or default-policy change follows from implementation checks.

## Distributed verification: v1.296.0

On 2026-09-07, the downloaded `kazi_macos_aarch64` release asset from v1.296.0
passed all eight public acceptance/bounded-repair scenarios. Its SHA-256 was
verified against the published checksum:
`5d49a7a990e755b87c1ac06c0e34fa8f721129da5d621645715312205cdb1e3d`.
It reports version `1.296.0`, schema 2. Both entry paths converge on the
second-launch repair, stop at exactly two failed launches, retain readable
hash-verified handoffs, admit the real behavioral-red fixture and reject the
blanket-success repair. The existing active executable was not replaced.
This closes the previously open E78/E79 distributed checks; it does not close
E74/E76 or authorize E77 paid runs.

## Dispatch-contract release: v1.296.1

The downloaded macOS arm64 artifact from v1.296.1 passed all 12 offline
scenarios, including four complete-contract cases across two launches. Its
SHA-256 is `bebf9516685bbb551e49d47b84c5c714f0f8ef2ecb6d10159c3b46ee5bfd9df9`.
PR #1844 merged as `3b3eec5e2469a8f6b50224e9a1daebd73222b13b` after
independent review and 5,047 CI cases passed (234 doctests, 4,813 tests),
with 124 excluded. This closes the E74 distributed gate.

Fanisi v0.1.0 also passed its distributed gate: 18 offline ledger checks on
the downloaded native artifact, four checksummed platform archives, and 90
race-enabled source cases. Its `docs/e80-release-validation.md` records the
source, artifact identities and limitations. E78/E79/E80 release gates are
complete. E76's final artifact result follows below.

## Accounting source verification

E76 adds nullable cumulative usage/provenance snapshots to runs and iterations.
Reports count once per launch, including failed launches and both worker roles;
missing reports remain in the coverage denominator. JSON consumers distinguish
unverified harness dollars from dated table estimates and unknown actual cost.
Historical rows stay unknown. Reasoning is retained as a subset of output and
is neither summed nor priced twice.

The scoped suite executed 250 passing tests. Deliberately dropping the
provenance fold caused eight failures; double-recording it caused eight failures.
Removing the final snapshot on sealed-input and rendered-node refusals caused
two failures. Restoring the implementation returned the full scoped suite to
green. These checks exercise public consumers and persistence, not only a
serializer. Independent review cleared the code after those refusal and
aggregate-cost-coverage fixes.

The installed smoke now includes four accounting cases: file and proposal
entry, failed first launch, and reported/unreported second launch. It checks
1,352,533 or 1,352,633 tokens and unverified $2.017401 across independent
`apply`, `status`, `economy` processes and retained SQLite rows. Release
certification required executing those cases against the produced artifact;
that gate is recorded below, separately from source verification.

## Accounting release: v1.297.0

[Kazi PR #1846](https://github.com/kazi-org/kazi/pull/1846) merged as
`d568b2c6f26635227ea22c8e33d8b3f5c1edc51d` after independent review and
5,063 passing CI cases (234 doctests, 4,829 tests), with 124 excluded.
The release source is `0b7c7f916f9c883e1c336c440b539c92667861e9`.

The downloaded macOS arm64 asset from
[v1.297.0](https://github.com/kazi-org/kazi/releases/tag/v1.297.0) passed all
16 offline scenarios: four bounded-repair, four acceptance-integrity, four
complete-dispatch-contract and four accounting cases. Its SHA-256 matches the
published checksum:
`9c2bdc135dad2ed09e781b4978448b3a5b3d3fd5cd5c940b7d1c2b32dd610dd7`.
The accounting checks read independent public CLI processes and persisted rows;
a missing second report stays partial coverage and never becomes zero usage.

Release workflow 34122056377 passed all four platform jobs and its publication
steps. Native local execution covered macOS arm64; the other architectures were
checked by their release jobs. The active Kazi executable was not replaced, and
these smoke scenarios made no paid provider requests.

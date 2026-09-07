# Accepted-change delivery evidence

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
Temporary evidence is retained for diagnosis.

Single-file Burrito packaging failed locally: the host Zig version was
incompatible, and retrying with the repository-pinned Zig 0.15.2 failed linking
macOS system symbols. The assembled release works; the distributed binary is
not yet certified. No active installation or subscription configuration changed.

## Remaining gates

E78/E79 release rows remain open until the final merged and distributed artifact
repeats the smoke. Fanisi's source is merged; its distributed-release check also
remains open. These facts must not be promoted to release certification.

E74's complete-contract implementation and 34 scoped checks are present after
the rebase. Its planned public `dispatch_contract_test.exs` fixture is absent;
that public/installed criterion remains unverified. E76's existing source
selection fix is reused and its adapter/usage tests pass. The public usage
renderer still exposes numeric cost without the planned cost-basis/source
provenance, so E76.2–E76.4 remain incomplete. No existing fix was rebuilt.

E77 preregistration remains dependency-gated. No new paid comparison was run,
no proposed budget was treated as spending authorization, and no productivity
claim or default-policy change follows from these implementation checks.

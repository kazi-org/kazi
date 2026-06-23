# ADR 0017: Automated brew release pipeline (release-please -> CI build -> tap auto-bump)

## Status
Accepted

## Date
2026-06-22

## Context

ADR-0014 chose Burrito + Homebrew as kazi's distribution: `brew install
kazi-org/tap/kazi` installs a single self-contained binary (ERTS + the exqlite
NIF bundled) with the full SQLite read-model. The mechanics are merged or in
flight (T6.1 `mix release`, the Burrito wrap config, T6.3 the release CI). What is
NOT yet decided is the *cadence and automation*: who decides the version, what
triggers a build, and how the Homebrew formula gets the new artifact.

The operator's ask is "auto release the brew packages" -- merging code should, with
no manual steps, produce a versioned release whose binaries are built, published,
checksummed, and reflected in the Homebrew tap so `brew install` / `brew upgrade`
always serve the latest. Doing this by hand (tag, wait for build, download
checksums, hand-edit the formula, commit to the tap) is exactly the toil to
remove, and a hand-edited formula is a recurring source of checksum/URL drift.

Constraints specific to kazi:
- The Burrito binaries can only be linked on Zig-compatible runners (macOS-15 /
  Ubuntu), NOT the macOS-26 dev host (R-E6-1, ADR-0014). So the build is
  inherently CI-driven.
- The formula lives in a SECOND repo (`kazi-org/homebrew-tap`); the default
  `GITHUB_TOKEN` of a workflow in `kazi-org/kazi` cannot push there.
- The repo already uses Conventional Commits (this is enforced by the commit
  discipline in the operating procedure).

## Decision

**A three-stage, fully-automated pipeline, each stage triggered by the previous,
starting from Conventional Commits on `main`:**

1. **Versioning -- release-please.** A `release-please` GitHub Action watches
   `main`, derives the next semver from Conventional Commits (`fix:` -> patch,
   `feat:` -> minor, `!`/`BREAKING CHANGE` -> major), and maintains a standing
   "release PR" that bumps the version in `mix.exs` and updates `CHANGELOG.md`.
   Merging that PR creates the `vX.Y.Z` tag and the GitHub Release. The human's
   only act is merging the release PR -- versioning is never hand-computed.

2. **Build + publish -- the release workflow.** Triggered by the `v*` tag (T6.3),
   a matrix builds the four Burrito targets (macOS aarch64/x86_64 on `macos-15`;
   Linux aarch64/x86_64 on `ubuntu-latest`) with Zig 0.15.2, generates a `.sha256`
   per binary, and uploads all of them as assets on the GitHub Release.

3. **Tap auto-bump -- the formula updater.** When the Release is published, a
   workflow regenerates the `kazi` formula in `kazi-org/homebrew-tap` -- new
   version, per-platform asset URLs, and the published `.sha256` values -- and
   pushes it, authenticated with a dedicated `HOMEBREW_TAP_TOKEN` (a fine-grained
   PAT scoped to `contents:write` on `homebrew-tap` only). `brew install` /
   `brew upgrade kazi-org/tap/kazi` then serve the latest with zero manual steps.

So: merge Conventional Commits -> merge the release PR -> binaries build, the
Release publishes, and the tap formula updates itself. No manual tag, no
hand-edited checksum, no manual formula commit.

## Consequences

- **Hands-off releases.** The only human action is reviewing+merging the
  release-please PR; everything downstream is automatic and reproducible.
- **No checksum/URL drift.** The formula is generated from the actual published
  assets, so its `sha256`s and URLs cannot diverge from what shipped -- the most
  common Homebrew-tap failure mode is eliminated.
- **CI is the only build path (intended).** Because the binaries can't link on the
  dev host (R-E6-1), CI-as-the-build is not a limitation but the design. A release
  can't be cut from a laptop, which also keeps it reproducible.
- **A cross-repo secret exists.** `HOMEBREW_TAP_TOKEN` is a fine-grained PAT scoped
  to one repo and one permission; it is the minimum authority for the cross-repo
  push and must be rotated like any deploy credential. This is the one piece of
  standing trust the automation requires.
- **Conventional Commits become load-bearing.** Version correctness depends on
  commit-message types; a mistyped commit yields the wrong bump. The repo already
  mandates Conventional Commits, so this tightens an existing rule rather than
  adding one.

## Alternatives rejected

- **Manual tagging + hand-edited formula.** The status quo for many small tools;
  rejected as ongoing toil and the documented source of checksum/URL drift. It also
  scales badly once there are four per-platform artifacts to checksum by hand.
- **GoReleaser-style single tool.** kazi is an Elixir/Burrito project, not Go;
  GoReleaser does not build Burrito artifacts. The release-please + matrix-build +
  formula-bump composition is the BEAM-ecosystem equivalent and reuses maintained
  Actions.
- **Vendoring the formula in the main repo (no second repo).** Homebrew taps are a
  separate-repo convention (`<org>/homebrew-<tap>`); fighting it complicates
  `brew install` and `brew audit`. Keep the tap as its own repo (ADR-0014) and
  push to it from CI.
- **Auto-merging the release PR too (zero human steps).** Rejected: the release PR
  is the one deliberate gate where a human confirms "ship this version now." Full
  auto-merge removes the only review point for an outward-facing publish; the cost
  (one click) is worth the control.

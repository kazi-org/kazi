# ADR 0019: Move the website to a dedicated kazi-org/website repo

## Status
Accepted (supersedes the LOCATION decision in ADR-0018; everything else in 0018 stands)

## Date
2026-06-23

## Context

ADR-0018 shipped the kazi website with Astro + Tailwind on GitHub Pages at
`kazi.sire.run`, and -- to keep copy close to the source and prevent drift --
placed it in the kazi product repo under `site/`. That is now live.

In practice, co-locating a marketing/content site with the Elixir product repo has
costs that outweigh the "copy stays close" benefit:

- **Mixed history + CI.** Every site tweak (a headline, a color) shows up in the
  product repo's commit history and can re-trigger product CI; the Pages deploy
  workflow lives beside the product's release/test workflows.
- **Contributor friction.** A designer or marketer can't touch the site without
  cloning and PR-ing the product repo, which is intimidating and over-broad.
- **Coupled cadence + surface area.** The product's versioning, releases, and issue
  tracker now also carry website concerns; the repo's "what is this project" signal
  is muddied (Elixir product + a JS/Astro site).

The original "prevent drift" rationale is preserved by the canonical-strings
drift-check (ADR-0018 T9.9) -- which can run cross-repo -- so the location no longer
has to buy coherence.

## Decision

**Move the website into a dedicated `kazi-org/website` repository.** Keep
everything else from ADR-0018: Astro + Tailwind, GitHub Pages via Actions, and the
`kazi.sire.run` custom domain.

- The website gets its own repo, CI, Pages deploy, and issue tracker.
- The `kazi.sire.run` custom domain moves from `kazi-org/kazi` to `kazi-org/website`
  (a custom domain can be claimed by only ONE repo). The DNS `CNAME`
  (`kazi -> kazi-org.github.io`, in `sirerun/foundation`) is UNCHANGED -- it points
  at GitHub Pages generally; which repo serves the domain is a Pages setting.
- The README <-> website coherence check (ADR-0018) becomes CROSS-REPO: the
  `website` repo's CI fetches kazi's raw `README.md` and asserts the shared
  canonical strings (install command, positioning one-liner) still match. The guard
  survives the split; it just reads the README over HTTP instead of from `../`.
- `site/` and the Pages workflow are removed from `kazi-org/kazi`; the kazi README
  keeps linking to `https://kazi.sire.run`.

## Consequences

- **Cleaner separation.** The product repo is Elixir-only again; the site has its
  own home, CI, and contributor on-ramp. Each evolves on its own cadence.
- **Coherence is preserved but cross-repo.** The drift-check reads kazi's README via
  `raw.githubusercontent.com` (pin to a branch/tag) -- one network read, still fails
  CI on divergence. Slightly more complex than a local file read.
- **A one-time domain hand-off with brief downtime.** Releasing `kazi.sire.run` on
  `kazi-org/kazi` Pages and claiming it on `kazi-org/website` re-runs GitHub's cert
  provisioning, so there is a short window (minutes) where HTTPS may be unavailable.
  Sequence it as one deliberate cutover (T10.3) and verify live after.
- **Migration cost is small and one-time** (create repo, move ~15 files, move the
  domain, adapt one workflow). After it, day-to-day site work never touches the
  product repo.

## Alternatives rejected

- **Keep the site in `kazi-org/kazi` (ADR-0018 status quo).** Rejected for the
  history/CI/contributor reasons above now that the drift-check makes coherence
  independent of co-location.
- **Monorepo with a second Pages source.** GitHub Pages deploys ONE source per repo
  and a custom domain attaches per repo, so a monorepo can't serve a separate
  site at `kazi.sire.run` without the same single-Pages constraint -- it buys nothing
  over the current `site/` layout.
- **A separate branch (e.g. `gh-pages`) instead of a separate repo.** Still mixes
  the site into the product repo's history and CI; a dedicated repo is the clean cut.

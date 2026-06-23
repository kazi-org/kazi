# ADR 0018: kazi website -- Astro + Tailwind on GitHub Pages at kazi.sire.run

## Status
Accepted

## Date
2026-06-23

## Context

kazi is a v1 open-source release (Apache-2.0, copyright Sire Run, Inc.) with a
working `brew install kazi-org/tap/kazi`, a multi-harness CLI, and rich docs in
the repo (`README.md`, `docs/concept.md`). It has no public website. A landing
site is the front door for adoption: it explains what kazi is ("the outer loop
existing agents lack"), shows the 60-second mental model, and gets a visitor from
"interested" to `brew install` + a first goal in one screen.

Three coupled decisions: (1) what to build the site with, (2) where to host it,
and (3) what domain to serve it from -- the operator specifically asked whether
`kazi.sire.run` makes sense.

Constraints/facts:
- The org has `kazi-org` (the repo) and the company owns `sire.run`.
- GitHub Pages is free, integrates with the repo, auto-provisions HTTPS, and
  supports custom domains. A SUBDOMAIN custom domain needs a single DNS `CNAME`
  record (`kazi` -> `kazi-org.github.io`); an APEX domain needs four A records +
  AAAA records to GitHub's IPs (more to misconfigure).
- Node v25 + npm are available; the repo already uses GitHub Actions.

## Decision

**Stack: Astro + Tailwind CSS**, a static-output content site. Astro ships zero
JS by default (excellent Lighthouse/perf for a marketing page), is content-first
(Markdown/MDX for future docs pages), and deploys to GitHub Pages trivially. It is
the right size: more maintainable than hand-written HTML as the site grows a docs
section, far lighter than an app framework (no Vue/Pinia -- this is content, not
an app). Tailwind carries the kazi brand (the Electric Blue gradient + the logo
assets in `assets/logo/`).

**Location: in the `kazi-org/kazi` repo under `site/`**, NOT a separate repo. The
site copy is derived from the same `README.md`/`docs/concept.md` it must stay true
to; keeping it one PR away from the source avoids drift. The custom domain makes
the GitHub Pages project path irrelevant.

**Hosting: GitHub Pages via GitHub Actions** (`actions/deploy-pages` +
`actions/upload-pages-artifact`), building Astro on push to `main`. HTTPS is
auto-provisioned by GitHub.

**Domain: `kazi.sire.run`** (recommended for v1). Set via a `public/CNAME` file
(`kazi.sire.run`) + one DNS `CNAME` record at the `sire.run` provider (operator
step) + "Enforce HTTPS" in repo Pages settings.

### Why kazi.sire.run

1. **Free and already owned** -- Sire Run, Inc. owns `sire.run` and holds kazi's
   copyright, so there is nothing to buy and we can ship today.
2. **Simplest, most robust GitHub Pages setup** -- a subdomain is one `CNAME` DNS
   record, not four+ apex A/AAAA records; less to get wrong, HTTPS just works.
3. **Honest branding** -- kazi IS a Sire Run open-source project; `<product>.<company>`
   reflects that cleanly, and the `.run` TLD is thematically apt (kazi *runs* goals
   to convergence).
4. **Reversible** -- GitHub Pages custom domains are trivial to change. If kazi
   later wants a standalone, vendor-neutral identity, migrate to a dedicated domain
   (e.g. `kazi.dev`) by swapping the `CNAME` file + DNS and adding a redirect; no
   lock-in.

The one trade-off: a subdomain frames kazi as "a Sire Run product" rather than an
independent community project. A dedicated neutral domain signals vendor-neutrality
better, which can help OSS adoption. For a v1 launch the cost/simplicity/honesty of
`kazi.sire.run` wins, and the choice is reversible -- so we take it now and can
revisit if kazi outgrows the company framing.

## Consequences

- **Ships fast, free, low-risk.** One DNS record + a CNAME file + a deploy
  workflow; no domain purchase, no apex DNS, automatic HTTPS.
- **One source of truth.** Site copy lives beside the docs it mirrors; a docs
  drift shows up in the same repo and is fixed in one PR.
- **Static + cheap + fast.** Zero-JS Astro output scores well on Core Web Vitals
  and has no server to run or pay for.
- **DNS is operator-gated.** The single `CNAME` record must be added at the
  `sire.run` DNS provider by whoever controls it; until then the site is reachable
  at the default `kazi-org.github.io/kazi` URL.
- **A future rebrand is a small, planned migration** (CNAME swap + redirect), not
  a rebuild.

## Alternatives rejected

- **Apex/dedicated domain now (`kazi.dev`, `getkazi.com`).** Costs money, needs
  apex A/AAAA DNS, and commits to an independent brand before there is traffic to
  justify it. Deferred -- `kazi.sire.run` is free and reversible.
- **Hand-written HTML/CSS.** Fine for a single static page but does not scale to a
  docs section and re-implements layout/asset plumbing Astro gives for free.
- **A docs-framework (Docusaurus/VitePress) or an app framework (Vue/Pinia).**
  Docs frameworks are heavy for a one-page launch; an app framework is the wrong
  tool for a static content site. Astro spans "landing now, docs later" without
  either's weight.
- **A separate website repo.** Cleaner code separation but invites copy/docs drift
  and a second CI/release surface; the custom domain already decouples the URL from
  the repo, so the separation buys little.

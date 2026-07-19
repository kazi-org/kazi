# Site instrumentation — analytics, UTM, and canonical URLs (T38.21)

Operational reference for the adoption blog series' instrumentation
(ADR-0048 dec. 8). It implements one rule: **measure ONE honest adoption signal,
privacy-respectingly, on a static site — never a vanity metric and never a
gated-capture funnel.** The editorial framing of the signal lives in
[`docs/blog-style.md`](blog-style.md); this file is the wiring.

## The one adoption signal

**Blog-attributed install intents** — the count of outbound clicks from a blog
page to the kazi repo / install that carry `utm_source=blog`. It is a
doc → install progression measure, not page views and not GitHub stars (per
ADR-0030, "instrument downloads/retention, not stars"). The series is judged by
this signal alone.

Why this signal: it is the closest privacy-respecting proxy for "the series moved
a reader toward adopting kazi" that a static, backend-less site can measure. It
needs no PII, no cookies, and no account on the reader's side.

## Analytics: cookieless, config-gated

- **Tool:** a [Plausible](https://plausible.io)-style include using the
  **outbound-links** script variant. Plausible is cookieless and
  GDPR/CCPA/PECR-compliant by design — no consent banner is required, and it
  stores no personal data. The outbound-links variant records clicks on links
  leaving the site, which is exactly the adoption signal above.
- **Where:** `site/src/components/Analytics.astro`, included site-wide from
  `site/src/layouts/Layout.astro` (so every page, blog and marketing, is covered;
  the UTM tags below distinguish blog-originated clicks).
- **Config-gated, never faked.** The include ships **wired but inactive**. It
  emits a tracker script ONLY when `PUBLIC_ANALYTICS_DOMAIN` is set at build time.
  When it is empty the page is script-free and carries a visible HTML comment
  (`<!-- kazi analytics: … inactive … -->`) so the build never pretends to be
  measuring when it is not. No placeholder endpoint is hardcoded.

### Turning it on

Analytics activates with **one variable, no code change**:

1. Provision a cookieless analytics site for `kazi.sire.run` (Plausible Cloud or
   self-hosted; or any provider exposing a compatible cookieless script).
2. Set the GitHub Actions **repo variable** `ANALYTICS_DOMAIN` to the analytics
   property (e.g. `kazi.sire.run`). The Pages workflow
   (`.github/workflows/pages.yml`) passes it to the build as
   `PUBLIC_ANALYTICS_DOMAIN`.
3. (Optional) self-hosted or alternate provider: set `PUBLIC_ANALYTICS_SRC` to the
   script URL. Defaults to Plausible Cloud's `script.outbound-links.js`.
4. Re-run the Pages deploy. The next build emits the tracker.

Until step 2 is done the site ships analytics-free by design — honest, not broken.

## UTM scheme for outbound links

Every outbound repo/install link **from a blog page** carries a fixed scheme so
the click is attributable to the series:

| Param | Value |
| --- | --- |
| `utm_source` | `blog` |
| `utm_medium` | `post` |
| `utm_campaign` | `vibe-to-reconciliation` |
| `utm_content` | the post id, the series slug, or `blog-index` |

- **Helper, not hand-rolled:** `site/src/utm.mjs` exports `withUtm(target,
  content)`; blog pages build their outbound repo link with it so the scheme can
  never drift. Posts that add their own outbound install/repo links MUST use this
  helper.
- Applied today on the post layout (`[...slug].astro`), the series landing page,
  and the blog index. Internal links and `sire.run` links are left untagged.

## Canonical-URL syndication rule (consumed by T38.19)

Every page renders `<link rel="canonical">` to its live `https://kazi.sire.run`
permalink — emitted automatically by `Layout.astro` from `Astro.site`, so every
post inherits it with no per-post action.

**The syndication rule:** any cross-post of a blog article to an external platform
(dev.to, Medium, Hashnode, a newsletter, etc.) **MUST set its `rel=canonical`
back to the original `https://kazi.sire.run/blog/<slug>` permalink.** This keeps
search-engine authority on the kazi site and avoids a duplicate-content penalty.
Cross-posts also carry the UTM scheme on their links back to the repo/install.
T38.19 (the announcement + cross-post kit) consumes this rule verbatim.

## Out of scope (ADR-0048)

No email capture, drip funnels, gated lead capture, or welcome sequences — the
site is static and gated capture cuts against the developer-respecting stance.
RSS (`/blog/rss.xml`, T38.4) is the subscription channel; this one signal is the
conversion measure.

## References

- [ADR-0048 — Adoption blog series: editorial stance](adr/0048-adoption-blog-series-editorial-stance.md) (decision 8)
- [ADR-0030 — Content marketing and agent-native positioning](adr/0030-content-marketing-agent-native-positioning.md)
- [`docs/blog-style.md`](blog-style.md) — the editorial style sheet (names the signal for authors)
- Code: `site/src/components/Analytics.astro`, `site/src/utm.mjs`, `site/src/layouts/Layout.astro`, `.github/workflows/pages.yml`

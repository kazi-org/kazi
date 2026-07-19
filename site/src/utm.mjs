// UTM tagging for outbound links from the blog (T38.21, ADR-0048 dec. 8).
//
// The adoption blog series is judged by ONE signal: blog-attributed install
// intents — outbound clicks from a blog page to the kazi repo/install. To make
// that signal attributable, every outbound repo/install link from a blog page
// carries a fixed UTM scheme so the destination (and the cookieless analytics
// outbound-link event) can credit the click to the series.
//
// The scheme is fixed by ADR-0048 dec. 8 / docs/blog-style.md:
//   utm_source=blog  utm_medium=post  utm_campaign=vibe-to-reconciliation
//   utm_content=<slug>   (the post id, the series slug, or "blog-index")
//
// Posts and blog pages MUST route outbound repo/install links through withUtm()
// rather than hand-appending query strings, so the scheme can never drift.
export const UTM_SOURCE = "blog";
export const UTM_MEDIUM = "post";
export const UTM_CAMPAIGN = "vibe-to-reconciliation";

// The canonical repo URL — the primary outbound install/repo target. Mirrors the
// `REPO` constant used across the blog pages; kept here so callers can build a
// tagged repo link in one call.
export const REPO_URL = "https://github.com/kazi-org/kazi";

/**
 * Append the fixed series UTM scheme to an outbound URL.
 *
 * @param {string} target  Absolute outbound URL (e.g. the repo or a release page).
 * @param {string} content The `utm_content` value: a post id, the series slug,
 *                         or a page label like "blog-index". Required so each
 *                         click is attributable to its origin page.
 * @returns {string} The URL with utm_source/medium/campaign/content set.
 */
export function withUtm(target, content) {
  const url = new URL(target);
  url.searchParams.set("utm_source", UTM_SOURCE);
  url.searchParams.set("utm_medium", UTM_MEDIUM);
  url.searchParams.set("utm_campaign", UTM_CAMPAIGN);
  if (content) url.searchParams.set("utm_content", content);
  return url.href;
}

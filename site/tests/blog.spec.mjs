// T38.2: smoke test for the blog index + the series landing page (served from
// dist/). Asserts ONLY what is genuinely true today.
//
// HONEST about the empty published set: until Post 1 ships (T38.6) the published
// blog set is EMPTY (the collection holds only a draft placeholder). So this test
// asserts the index renders its empty state — it does NOT assert "≥1 published
// post". That "lists at least one post" assertion (from the plan acc) is
// deliberately DEFERRED to Post 1 (T38.6); faking a published post to satisfy it
// would be dishonest.
import { test, expect } from "@playwright/test";

const SERIES_SLUG = "from-vibe-coding-to-reconciliation";

function watchConsole(page) {
  const errors = [];
  page.on("console", (msg) => {
    if (msg.type() === "error") errors.push(msg.text());
  });
  page.on("pageerror", (err) => errors.push(String(err)));
  return errors;
}

test.describe("blog index", () => {
  test("/blog returns 200 and renders", async ({ page }) => {
    const res = await page.goto("/blog");
    expect(res?.status()).toBe(200);
    await expect(page.getByRole("heading", { name: "The kazi blog" })).toBeVisible();
  });

  test("/blog is empty-safe (shows the empty state, no faked post)", async ({
    page,
  }) => {
    await page.goto("/blog");
    // Published set is honestly empty until T38.6 → the empty state renders, and
    // there is no post list. (When Post 1 ships, this flips to a post list; the
    // "≥1 post" assertion is deferred to that task.)
    await expect(page.locator("#blog-empty-state")).toBeVisible();
    await expect(page.getByText("Posts coming soon")).toBeVisible();
    await expect(page.locator("#blog-post-list")).toHaveCount(0);
  });

  test("/blog loads with no console errors", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto("/blog", { waitUntil: "networkidle" });
    expect(errors, `console errors on /blog:\n${errors.join("\n")}`).toEqual([]);
  });
});

test.describe("series landing page", () => {
  test("returns 200 and renders the title", async ({ page }) => {
    const res = await page.goto(`/blog/${SERIES_SLUG}`);
    expect(res?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { name: "From Vibe Coding to Reconciliation" }),
    ).toBeVisible();
  });

  test("lists all 12 parts in ascending part order", async ({ page }) => {
    await page.goto(`/blog/${SERIES_SLUG}`);
    const items = page.locator("#series-parts > li");
    await expect(items).toHaveCount(12);
    // The rendered `data-part` sequence must be strictly ascending 1..12.
    const parts = await items.evaluateAll((els) =>
      els.map((el) => Number(el.getAttribute("data-part"))),
    );
    expect(parts).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
  });

  test("marks unpublished parts as coming", async ({ page }) => {
    await page.goto(`/blog/${SERIES_SLUG}`);
    // No post is published yet, so every part carries the "coming" badge. Scope
    // to the badges inside the parts list (the intro prose also uses the word).
    await expect(
      page.locator("#series-parts .ui-chip", { hasText: "coming" }),
    ).toHaveCount(12);
  });

  test("loads with no console errors", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto(`/blog/${SERIES_SLUG}`, { waitUntil: "networkidle" });
    expect(errors, `console errors on series page:\n${errors.join("\n")}`).toEqual(
      [],
    );
  });
});

// T38.21: series instrumentation. Asserted against the PUBLISHED series landing
// page (a real, shipped blog page) rather than a faked post — the per-post
// canonical/UTM behaviour is identical (both render through Layout.astro + the
// shared withUtm helper), so this exercises the true contract without minting a
// fake published post (which the honesty discipline above forbids).
test.describe("series instrumentation (T38.21)", () => {
  const SERIES_URL = `/blog/${SERIES_SLUG}`;

  test("emits a canonical URL pointing back to the live permalink", async ({
    page,
  }) => {
    await page.goto(SERIES_URL);
    const canonical = page.locator('link[rel="canonical"]');
    await expect(canonical).toHaveCount(1);
    // The canonical is the live-site permalink (Astro.site = https://kazi.sire.run),
    // not the local preview origin — that is what cross-posts must point back to.
    const href = await canonical.getAttribute("href");
    // Live-site permalink (Astro emits a trailing slash for directory routes).
    expect(href.replace(/\/$/, "")).toBe(`https://kazi.sire.run${SERIES_URL}`);
  });

  test("outbound repo link carries the full UTM scheme", async ({ page }) => {
    await page.goto(SERIES_URL);
    const repoLink = page
      .locator('nav[aria-label="Primary"] a', { hasText: "GitHub" })
      .first();
    const href = await repoLink.getAttribute("href");
    const url = new URL(href);
    expect(url.origin + url.pathname).toBe("https://github.com/kazi-org/kazi");
    expect(url.searchParams.get("utm_source")).toBe("blog");
    expect(url.searchParams.get("utm_medium")).toBe("post");
    expect(url.searchParams.get("utm_campaign")).toBe("vibe-to-reconciliation");
    expect(url.searchParams.get("utm_content")).toBe(SERIES_SLUG);
  });

  test("ships the cookieless analytics include (inactive without a domain)", async ({
    page,
  }) => {
    const res = await page.goto(SERIES_URL);
    const html = (await res?.text()) ?? "";
    // The include is config-gated: with no PUBLIC_ANALYTICS_DOMAIN at build time it
    // emits NO tracker script, only an honest marker comment. (When a domain is
    // set, this flips to a <script data-domain> Plausible include.)
    const hasMarker = html.includes("kazi analytics:");
    const hasTracker =
      html.includes("data-domain") && html.includes("plausible.io");
    expect(
      hasMarker || hasTracker,
      "expected the analytics include (marker comment or tracker script) in the page HTML",
    ).toBe(true);
  });
});

// T38.3: the per-post route ([...slug].astro). The published set is honestly
// empty today (only a draft placeholder exists), so the production build emits
// NO post page — and the route's getStaticPaths excludes drafts. We assert the
// honest, true-today contract: a draft post is NOT reachable in the shipped
// site (404). The "a published post renders at /blog/<slug> with correct meta +
// working prev/next" assertion is exercised LOCALLY in dev (where drafts are
// previewable) and was verified during T38.3; it is deferred here to Post 1
// (T38.6), exactly as the index's "≥1 post" assertion is — faking a published
// post to green this would be dishonest.
test.describe("blog post route", () => {
  test("draft posts are excluded from the production build (404)", async ({
    page,
  }) => {
    const res = await page.goto("/blog/welcome");
    expect(res?.status()).toBe(404);
  });
});

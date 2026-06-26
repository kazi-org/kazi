// T38.2: smoke test for the blog index + the series landing page (served from
// dist/). Asserts ONLY what is genuinely true today.
//
// T38.6 shipped Post 1, so the published blog set is no longer empty: the index
// now lists at least one post (the "≥1 published post" assertion the plan acc
// deferred from T38.2 is fulfilled here), and the series landing page flips
// Part 1's row from "coming" to a live link.
//
// T38.7 shipped Post 2, so the published set is now two: the index lists both,
// and the series landing page flips Part 2's row to a live link as well (two
// "published" badges, ten "coming").
//
// T38.8 shipped Post 3, so the published set is now three: the index lists all
// three, and the series landing page flips Part 3's row to a live link too (three
// "published" badges, nine "coming").
//
// T38.9 shipped Post 4, so the published set is now four: the index lists all
// four, and the series landing page flips Part 4's row to a live link too (four
// "published" badges, eight "coming").
import { test, expect } from "@playwright/test";

const SERIES_SLUG = "from-vibe-coding-to-reconciliation";
// Post 1 (T38.6). Its filename is the slug; the per-post route is /blog/<slug>.
const POST1_SLUG = "the-ceiling-of-looks-good-to-me";
const POST1_TITLE = 'The ceiling of "looks good to me"';
// Post 2 (T38.7).
const POST2_SLUG = "teach-your-agent-to-remember";
const POST2_TITLE = "Teach your agent to remember";
// Post 3 (T38.8).
const POST3_SLUG = "decisions-need-a-home";
const POST3_TITLE = "Decisions need a home: knowledge tiers (and keeping them honest)";
// Post 4 (T38.9).
const POST4_SLUG = "give-your-agent-eyes";
const POST4_TITLE = "Give your agent eyes (all the way to prod)";

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

  test("/blog lists the published post(s), no empty state (T38.6)", async ({
    page,
  }) => {
    await page.goto("/blog");
    // Posts 1–3 are published → the post list renders and the empty state is gone.
    await expect(page.locator("#blog-empty-state")).toHaveCount(0);
    await expect(page.locator("#blog-post-list")).toBeVisible();
    const items = page.locator("#blog-post-list > li");
    await expect(items.first()).toBeVisible();
    // Posts 1–3 are listed and link to their per-post routes (T38.8).
    await expect(
      page.locator(`#blog-post-list a[href="/blog/${POST1_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#blog-post-list a[href="/blog/${POST2_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#blog-post-list a[href="/blog/${POST3_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#blog-post-list a[href="/blog/${POST4_SLUG}"]`),
    ).toHaveCount(1);
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

  test("marks the published part(s) and the rest as coming (T38.9)", async ({
    page,
  }) => {
    await page.goto(`/blog/${SERIES_SLUG}`);
    // Posts 1–4 are published; the remaining 8 still carry the "coming" badge.
    // Scope to the badges inside the parts list (the intro prose also uses the word).
    await expect(
      page.locator("#series-parts .ui-chip", { hasText: "coming" }),
    ).toHaveCount(8);
    await expect(
      page.locator("#series-parts .ui-chip", { hasText: "published" }),
    ).toHaveCount(4);
    // Parts 1–4 rows link to the live posts.
    await expect(
      page.locator(`#series-parts a[href="/blog/${POST1_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#series-parts a[href="/blog/${POST2_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#series-parts a[href="/blog/${POST3_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#series-parts a[href="/blog/${POST4_SLUG}"]`),
    ).toHaveCount(1);
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

// T38.20: visual assets — the three core explanatory diagrams (reconcile loop,
// rung ladder, without/with before-after) and per-post header art render on the
// series page with descriptive alt text, and the SVG assets are served.
test.describe("series visual assets (T38.20)", () => {
  const CORE_DIAGRAMS = [
    "/diagrams/reconcile-loop.svg",
    "/diagrams/ladder.svg",
    "/diagrams/before-after.svg",
  ];

  test("renders the three core diagrams with non-empty alt text", async ({
    page,
  }) => {
    await page.goto(`/blog/${SERIES_SLUG}`);
    for (const src of CORE_DIAGRAMS) {
      const img = page.locator(`img[src="${src}"]`);
      await expect(img).toHaveCount(1);
      const alt = (await img.getAttribute("alt"))?.trim() ?? "";
      expect(alt.length, `empty alt on ${src}`).toBeGreaterThan(0);
    }
  });

  test("renders per-post header art for all 12 parts with alt text", async ({
    page,
  }) => {
    await page.goto(`/blog/${SERIES_SLUG}`);
    const arts = page.locator('#series-parts img[src^="/blog/art/part-"]');
    await expect(arts).toHaveCount(12);
    const alts = await arts.evaluateAll((els) =>
      els.map((el) => (el.getAttribute("alt") ?? "").trim()),
    );
    expect(alts.every((a) => a.length > 0), `some art has empty alt`).toBe(true);
  });

  test("diagram + per-post art SVGs are served (200, image/svg+xml)", async ({
    page,
  }) => {
    const assets = [
      ...CORE_DIAGRAMS,
      "/blog/art/part-01.svg",
      "/blog/art/part-12.svg",
    ];
    for (const src of assets) {
      const res = await page.request.get(src);
      expect(res.status(), `status for ${src}`).toBe(200);
      expect(res.headers()["content-type"], `mime for ${src}`).toContain("svg");
    }
  });
});

// T38.3 / T38.6: the per-post route ([...slug].astro). Post 1 is now a real
// published post, so we assert it renders at its permalink with the correct
// header (title) and a header image carrying non-empty alt text. Drafts remain
// excluded from the production build (the welcome placeholder 404s).
test.describe("blog post route", () => {
  test("draft posts are excluded from the production build (404)", async ({
    page,
  }) => {
    const res = await page.goto("/blog/welcome");
    expect(res?.status()).toBe(404);
  });

  test("Post 1 renders at its permalink with title + header image (T38.6)", async ({
    page,
  }) => {
    const res = await page.goto(`/blog/${POST1_SLUG}`);
    expect(res?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { level: 1, name: POST1_TITLE }),
    ).toBeVisible();
    // Header image is the per-post art, with non-empty alt text.
    const hero = page.locator('main article img[src="/blog/art/part-01.svg"]');
    await expect(hero).toHaveCount(1);
    const alt = (await hero.getAttribute("alt"))?.trim() ?? "";
    expect(alt.length, "empty alt on the post header image").toBeGreaterThan(0);
  });

  test("Post 1 loads with no console errors (T38.6)", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto(`/blog/${POST1_SLUG}`, { waitUntil: "networkidle" });
    expect(
      errors,
      `console errors on the post:\n${errors.join("\n")}`,
    ).toEqual([]);
  });

  test("Post 2 renders at its permalink with title + header image (T38.7)", async ({
    page,
  }) => {
    const res = await page.goto(`/blog/${POST2_SLUG}`);
    expect(res?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { level: 1, name: POST2_TITLE }),
    ).toBeVisible();
    // Header image is the per-post art, with non-empty alt text.
    const hero = page.locator('main article img[src="/blog/art/part-02.svg"]');
    await expect(hero).toHaveCount(1);
    const alt = (await hero.getAttribute("alt"))?.trim() ?? "";
    expect(alt.length, "empty alt on the post header image").toBeGreaterThan(0);
  });

  test("Post 2 loads with no console errors (T38.7)", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto(`/blog/${POST2_SLUG}`, { waitUntil: "networkidle" });
    expect(
      errors,
      `console errors on the post:\n${errors.join("\n")}`,
    ).toEqual([]);
  });

  test("Post 3 renders at its permalink with title + header image (T38.8)", async ({
    page,
  }) => {
    const res = await page.goto(`/blog/${POST3_SLUG}`);
    expect(res?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { level: 1, name: POST3_TITLE }),
    ).toBeVisible();
    // Header image is the per-post art, with non-empty alt text.
    const hero = page.locator('main article img[src="/blog/art/part-03.svg"]');
    await expect(hero).toHaveCount(1);
    const alt = (await hero.getAttribute("alt"))?.trim() ?? "";
    expect(alt.length, "empty alt on the post header image").toBeGreaterThan(0);
  });

  test("Post 3 loads with no console errors (T38.8)", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto(`/blog/${POST3_SLUG}`, { waitUntil: "networkidle" });
    expect(
      errors,
      `console errors on the post:\n${errors.join("\n")}`,
    ).toEqual([]);
  });

  test("Post 4 renders at its permalink with title + header image (T38.9)", async ({
    page,
  }) => {
    const res = await page.goto(`/blog/${POST4_SLUG}`);
    expect(res?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { level: 1, name: POST4_TITLE }),
    ).toBeVisible();
    // Header image is the per-post art, with non-empty alt text.
    const hero = page.locator('main article img[src="/blog/art/part-04.svg"]');
    await expect(hero).toHaveCount(1);
    const alt = (await hero.getAttribute("alt"))?.trim() ?? "";
    expect(alt.length, "empty alt on the post header image").toBeGreaterThan(0);
  });

  test("Post 4 loads with no console errors (T38.9)", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto(`/blog/${POST4_SLUG}`, { waitUntil: "networkidle" });
    expect(
      errors,
      `console errors on the post:\n${errors.join("\n")}`,
    ).toEqual([]);
  });
});

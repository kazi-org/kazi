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
//
// T38.10 shipped Post 5, so the published set is now five: the index lists all
// five, and the series landing page flips Part 5's row to a live link too (five
// "published" badges, seven "coming").
//
// T38.11 shipped Post 6, so the published set is now six: the index lists all
// six, and the series landing page flips Part 6's row to a live link too (six
// "published" badges, six "coming").
//
// T38.12 shipped Post 7, so the published set is now seven: the index lists all
// seven, and the series landing page flips Part 7's row to a live link too (seven
// "published" badges, five "coming").
//
// T38.13 shipped Post 8, so the published set is now eight: the index lists all
// eight, and the series landing page flips Part 8's row to a live link too (eight
// "published" badges, four "coming").
//
// T38.14 shipped Post 9, so the published set is now nine: the index lists all
// nine, and the series landing page flips Part 9's row to a live link too (nine
// "published" badges, three "coming").
//
// T38.15 shipped Post 10, so the published set is now ten: the index lists all
// ten, and the series landing page flips Part 10's row to a live link too (ten
// "published" badges, two "coming").
//
// T38.16 shipped Post 11, so the published set is now eleven: the index lists all
// eleven, and the series landing page flips Part 11's row to a live link too
// (eleven "published" badges, one "coming").
//
// T38.17 shipped Post 12 (the finale), so the published set is now the full twelve:
// the index lists all twelve, and the series landing page flips Part 12's row to a
// live link too (twelve "published" badges, zero "coming").
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
// Post 5 (T38.10).
const POST5_SLUG = "stop-re-reading-the-whole-repo";
const POST5_TITLE = "Stop re-reading the whole repo (and refactor without fear)";
// Post 6 (T38.11).
const POST6_SLUG = "from-prompts-to-skills";
const POST6_TITLE = "From prompts to skills";
// Post 7 (T38.12).
const POST7_SLUG = "plan-the-work-then-work-the-plan";
const POST7_TITLE = "Plan the work, then work the plan";
// Post 8 (T38.13).
const POST8_SLUG = "a-definition-of-done-that-cant-lie";
const POST8_TITLE = 'A definition of "done" that can\'t lie';
// Post 9 (T38.14).
const POST9_SLUG = "one-developer-many-agents";
const POST9_TITLE = "One developer, many agents (and how to recover)";
// Post 10 (T38.15).
const POST10_SLUG = "the-pattern-underneath-reconciliation";
const POST10_TITLE = "The pattern underneath: reconciliation";
// Post 11 (T38.16).
const POST11_SLUG = "meet-kazi-done-proven";
const POST11_TITLE = 'Meet kazi: "done," proven';
// Post 12 (T38.17) — the finale.
const POST12_SLUG = "your-on-ramp";
const POST12_TITLE = "Your on-ramp";

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
    await expect(
      page.locator(`#blog-post-list a[href="/blog/${POST5_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#blog-post-list a[href="/blog/${POST6_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#blog-post-list a[href="/blog/${POST7_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#blog-post-list a[href="/blog/${POST8_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#blog-post-list a[href="/blog/${POST9_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#blog-post-list a[href="/blog/${POST10_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#blog-post-list a[href="/blog/${POST11_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#blog-post-list a[href="/blog/${POST12_SLUG}"]`),
    ).toHaveCount(1);
  });

  test("/blog lists the series in reading order, Part 1 → Part 12", async ({
    page,
  }) => {
    // Every adoption-series post shares one publish date, so a date-only sort is
    // unstable and scrambles the series. The index sorts by date then part, so
    // the rendered order must be ascending by part (Part 1 first).
    await page.goto("/blog");
    const expected = [
      POST1_SLUG,
      POST2_SLUG,
      POST3_SLUG,
      POST4_SLUG,
      POST5_SLUG,
      POST6_SLUG,
      POST7_SLUG,
      POST8_SLUG,
      POST9_SLUG,
      POST10_SLUG,
      POST11_SLUG,
      POST12_SLUG,
    ];
    const hrefs = await page
      .locator("#blog-post-list > li a[href^='/blog/']")
      .evaluateAll((els) =>
        els
          .map((el) => el.getAttribute("href"))
          .filter((h) => h && !h.endsWith("/blog")),
      );
    const order = hrefs.map((h) => h.replace(/^\/blog\//, "").replace(/\/$/, ""));
    // Keep only the per-post links (one per post), preserving DOM order.
    const seen = [];
    for (const slug of order) {
      if (expected.includes(slug) && !seen.includes(slug)) seen.push(slug);
    }
    expect(seen).toEqual(expected);
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

  test("marks the published part(s) and the rest as coming (T38.17)", async ({
    page,
  }) => {
    await page.goto(`/blog/${SERIES_SLUG}`);
    // All 12 posts are published; no "coming" badge remains.
    // Scope to the badges inside the parts list (the intro prose also uses the word).
    await expect(
      page.locator("#series-parts .ui-chip", { hasText: "coming" }),
    ).toHaveCount(0);
    await expect(
      page.locator("#series-parts .ui-chip", { hasText: "published" }),
    ).toHaveCount(12);
    // Parts 1–5 rows link to the live posts.
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
    await expect(
      page.locator(`#series-parts a[href="/blog/${POST5_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#series-parts a[href="/blog/${POST6_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#series-parts a[href="/blog/${POST7_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#series-parts a[href="/blog/${POST8_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#series-parts a[href="/blog/${POST9_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#series-parts a[href="/blog/${POST10_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#series-parts a[href="/blog/${POST11_SLUG}"]`),
    ).toHaveCount(1);
    await expect(
      page.locator(`#series-parts a[href="/blog/${POST12_SLUG}"]`),
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

  test("Post 5 renders at its permalink with title + header image (T38.10)", async ({
    page,
  }) => {
    const res = await page.goto(`/blog/${POST5_SLUG}`);
    expect(res?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { level: 1, name: POST5_TITLE }),
    ).toBeVisible();
    // Header image is the per-post art, with non-empty alt text.
    const hero = page.locator('main article img[src="/blog/art/part-05.svg"]');
    await expect(hero).toHaveCount(1);
    const alt = (await hero.getAttribute("alt"))?.trim() ?? "";
    expect(alt.length, "empty alt on the post header image").toBeGreaterThan(0);
  });

  test("Post 5 loads with no console errors (T38.10)", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto(`/blog/${POST5_SLUG}`, { waitUntil: "networkidle" });
    expect(
      errors,
      `console errors on the post:\n${errors.join("\n")}`,
    ).toEqual([]);
  });

  test("Post 6 renders at its permalink with title + header image (T38.11)", async ({
    page,
  }) => {
    const res = await page.goto(`/blog/${POST6_SLUG}`);
    expect(res?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { level: 1, name: POST6_TITLE }),
    ).toBeVisible();
    // Header image is the per-post art, with non-empty alt text.
    const hero = page.locator('main article img[src="/blog/art/part-06.svg"]');
    await expect(hero).toHaveCount(1);
    const alt = (await hero.getAttribute("alt"))?.trim() ?? "";
    expect(alt.length, "empty alt on the post header image").toBeGreaterThan(0);
  });

  test("Post 6 loads with no console errors (T38.11)", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto(`/blog/${POST6_SLUG}`, { waitUntil: "networkidle" });
    expect(
      errors,
      `console errors on the post:\n${errors.join("\n")}`,
    ).toEqual([]);
  });

  test("Post 7 renders at its permalink with title + header image (T38.12)", async ({
    page,
  }) => {
    const res = await page.goto(`/blog/${POST7_SLUG}`);
    expect(res?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { level: 1, name: POST7_TITLE }),
    ).toBeVisible();
    // Header image is the per-post art, with non-empty alt text.
    const hero = page.locator('main article img[src="/blog/art/part-07.svg"]');
    await expect(hero).toHaveCount(1);
    const alt = (await hero.getAttribute("alt"))?.trim() ?? "";
    expect(alt.length, "empty alt on the post header image").toBeGreaterThan(0);
  });

  test("Post 7 loads with no console errors (T38.12)", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto(`/blog/${POST7_SLUG}`, { waitUntil: "networkidle" });
    expect(
      errors,
      `console errors on the post:\n${errors.join("\n")}`,
    ).toEqual([]);
  });

  test("Post 8 renders at its permalink with title + header image (T38.13)", async ({
    page,
  }) => {
    const res = await page.goto(`/blog/${POST8_SLUG}`);
    expect(res?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { level: 1, name: POST8_TITLE }),
    ).toBeVisible();
    // Header image is the per-post art, with non-empty alt text.
    const hero = page.locator('main article img[src="/blog/art/part-08.svg"]');
    await expect(hero).toHaveCount(1);
    const alt = (await hero.getAttribute("alt"))?.trim() ?? "";
    expect(alt.length, "empty alt on the post header image").toBeGreaterThan(0);
  });

  test("Post 8 loads with no console errors (T38.13)", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto(`/blog/${POST8_SLUG}`, { waitUntil: "networkidle" });
    expect(
      errors,
      `console errors on the post:\n${errors.join("\n")}`,
    ).toEqual([]);
  });

  test("Post 9 renders at its permalink with title + header image (T38.14)", async ({
    page,
  }) => {
    const res = await page.goto(`/blog/${POST9_SLUG}`);
    expect(res?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { level: 1, name: POST9_TITLE }),
    ).toBeVisible();
    // Header image is the per-post art, with non-empty alt text.
    const hero = page.locator('main article img[src="/blog/art/part-09.svg"]');
    await expect(hero).toHaveCount(1);
    const alt = (await hero.getAttribute("alt"))?.trim() ?? "";
    expect(alt.length, "empty alt on the post header image").toBeGreaterThan(0);
  });

  test("Post 9 loads with no console errors (T38.14)", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto(`/blog/${POST9_SLUG}`, { waitUntil: "networkidle" });
    expect(
      errors,
      `console errors on the post:\n${errors.join("\n")}`,
    ).toEqual([]);
  });

  test("Post 10 renders at its permalink with title + header image (T38.15)", async ({
    page,
  }) => {
    const res = await page.goto(`/blog/${POST10_SLUG}`);
    expect(res?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { level: 1, name: POST10_TITLE }),
    ).toBeVisible();
    // Header image is the per-post art, with non-empty alt text.
    const hero = page.locator('main article img[src="/blog/art/part-10.svg"]');
    await expect(hero).toHaveCount(1);
    const alt = (await hero.getAttribute("alt"))?.trim() ?? "";
    expect(alt.length, "empty alt on the post header image").toBeGreaterThan(0);
  });

  test("Post 10 loads with no console errors (T38.15)", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto(`/blog/${POST10_SLUG}`, { waitUntil: "networkidle" });
    expect(
      errors,
      `console errors on the post:\n${errors.join("\n")}`,
    ).toEqual([]);
  });

  test("Post 11 renders at its permalink with title + header image (T38.16)", async ({
    page,
  }) => {
    const res = await page.goto(`/blog/${POST11_SLUG}`);
    expect(res?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { level: 1, name: POST11_TITLE }),
    ).toBeVisible();
    // Header image is the per-post art, with non-empty alt text.
    const hero = page.locator('main article img[src="/blog/art/part-11.svg"]');
    await expect(hero).toHaveCount(1);
    const alt = (await hero.getAttribute("alt"))?.trim() ?? "";
    expect(alt.length, "empty alt on the post header image").toBeGreaterThan(0);
  });

  test("Post 11 loads with no console errors (T38.16)", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto(`/blog/${POST11_SLUG}`, { waitUntil: "networkidle" });
    expect(
      errors,
      `console errors on the post:\n${errors.join("\n")}`,
    ).toEqual([]);
  });

  test("Post 12 renders at its permalink with title + header image (T38.17)", async ({
    page,
  }) => {
    const res = await page.goto(`/blog/${POST12_SLUG}`);
    expect(res?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { level: 1, name: POST12_TITLE }),
    ).toBeVisible();
    // Header image is the per-post art, with non-empty alt text.
    const hero = page.locator('main article img[src="/blog/art/part-12.svg"]');
    await expect(hero).toHaveCount(1);
    const alt = (await hero.getAttribute("alt"))?.trim() ?? "";
    expect(alt.length, "empty alt on the post header image").toBeGreaterThan(0);
  });

  test("Post 12 loads with no console errors (T38.17)", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto(`/blog/${POST12_SLUG}`, { waitUntil: "networkidle" });
    expect(
      errors,
      `console errors on the post:\n${errors.join("\n")}`,
    ).toEqual([]);
  });
});

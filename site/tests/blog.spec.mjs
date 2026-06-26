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

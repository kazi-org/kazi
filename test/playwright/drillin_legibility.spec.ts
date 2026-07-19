import { test, expect } from "@playwright/test";

/**
 * T63.11 browser certification of the drill-in legibility redesign (UC-062,
 * the approved #1379 mock): the view leads with a purpose line and an on-page
 * legend a first-time viewer can decode; a goal with zero recorded iterations
 * renders an honest empty state, not a broken heatmap.
 *
 * Hermetic: the dashboard server boots in shared-sandbox mode (see
 * priv/playwright/server.exs); /test/seed stages "ship-the-api" with two
 * iterations, /test/reset clears the projection. Run serially because both
 * specs mutate the one shared read-model.
 */
test.describe.serial("drill-in legibility (T63.11)", () => {
  test("golden path: purpose line, summary, and annotated legend are visible", async ({
    page,
    request,
  }) => {
    const seed = await request.post("/test/seed");
    expect(seed.status()).toBe(200);

    await page.goto("/goals/ship-the-api/drillin");

    // Purpose statement leads the view.
    const purpose = page.locator("#drillin-purpose");
    await expect(purpose).toBeVisible();
    await expect(purpose).toContainText("which predicate is blocking this goal");

    // Plain-language summary and the decodable legend both render.
    await expect(page.locator("#drillin-summary")).toBeVisible();
    const legend = page.locator("#drillin-legend");
    await expect(legend).toBeVisible();
    await expect(legend.locator('[data-legend="pass"]')).toContainText(
      "pass — predicate satisfied",
    );
    await expect(legend.locator('[data-legend="fail"]')).toBeVisible();
    await expect(legend.locator('[data-legend="regression-flip"]')).toBeVisible();

    // The heatmap itself still renders.
    await expect(page.locator("#drillin-matrix")).toBeVisible();
  });

  test("edge case: a goal with zero iterations renders an honest empty state", async ({
    page,
    request,
  }) => {
    const reset = await request.post("/test/reset");
    expect(reset.status()).toBe(200);

    await page.goto("/goals/ship-the-api/drillin");

    // The purpose line still explains what the view is for...
    await expect(page.locator("#drillin-purpose")).toBeVisible();
    // ...and the empty state is honest, not a broken heatmap.
    const empty = page.locator("#drillin-empty");
    await expect(empty).toBeVisible();
    await expect(empty).toContainText("not an error");
    await expect(page.locator("#drillin-matrix")).toHaveCount(0);
    await expect(page.locator("#drillin-summary")).toHaveCount(0);
  });
});

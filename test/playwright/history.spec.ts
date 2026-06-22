import { test, expect } from "@playwright/test";

/**
 * T3.6d browser certification of the per-goal history view (UC-018).
 *
 * Hermetic: the dashboard server boots in shared-sandbox mode (see
 * priv/playwright/server.exs), so the test-only /test/seed endpoint stages the
 * read-model the timeline renders — no NATS, no harness. The seed records two
 * ordered iterations for "ship-the-api" (iteration 0 with a failing probe,
 * iteration 1 converged with a passing probe), which is exactly the ordered
 * timeline this spec asserts on. Run serially because it shares the one
 * read-model.
 */
test.describe.serial("history timeline", () => {
  test("ordered iteration/evidence timeline renders for a goal", async ({
    page,
    request,
  }) => {
    const seed = await request.post("/test/seed");
    expect(seed.status()).toBe(200);

    await page.goto("/goals/ship-the-api/history");

    await expect(page.locator("#history")).toBeVisible();
    await expect(page.locator("#history")).toHaveAttribute(
      "data-goal-ref",
      "ship-the-api",
    );
    await expect(
      page.getByRole("heading", { name: "kazi history · ship-the-api" }),
    ).toBeVisible();

    const timeline = page.locator("#timeline");
    await expect(timeline).toBeVisible();

    // Two iterations, in ascending order: 0 then 1.
    const items = timeline.locator("li.iteration");
    await expect(items).toHaveCount(2);
    await expect(items.nth(0)).toHaveAttribute("data-iteration-index", "0");
    await expect(items.nth(1)).toHaveAttribute("data-iteration-index", "1");

    // Iteration 0: probe failed, evidence shows the 503.
    const first = page.locator("#iteration-0");
    await expect(
      first.locator("#iteration-0-predicate-probe [data-status]"),
    ).toHaveAttribute("data-status", "fail");
    await expect(
      first.locator("#iteration-0-predicate-probe .predicate-evidence"),
    ).toContainText("http_status=503");

    // Iteration 1: converged, probe passed, evidence shows the 200.
    const second = page.locator("#iteration-1");
    await expect(second.locator("[data-converged]")).toHaveAttribute(
      "data-converged",
      "true",
    );
    await expect(
      second.locator("#iteration-1-predicate-probe [data-status]"),
    ).toHaveAttribute("data-status", "pass");
    await expect(
      second.locator("#iteration-1-predicate-probe .predicate-evidence"),
    ).toContainText("http_status=200");
  });

  test("a goal with no iterations renders the empty state", async ({
    page,
    request,
  }) => {
    const reset = await request.post("/test/reset");
    expect(reset.status()).toBe(200);

    await page.goto("/goals/never-ran/history");

    await expect(page.locator("#history")).toBeVisible();
    await expect(page.locator("#history-empty")).toBeVisible();
    await expect(page.locator("#history-empty")).toContainText(
      "No iterations recorded",
    );
    await expect(page.locator("#timeline")).toHaveCount(0);
  });
});

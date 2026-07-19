import { test, expect } from "@playwright/test";

/**
 * T63.12 browser certification of the narrative per-goal history view (#1379
 * mock, UC-062). Rebuilt from the T3.6d raw-timeline spec: the view now renders
 * NEWEST-FIRST narrative events with a plain-language convergence summary.
 *
 * Hermetic: the dashboard server boots in shared-sandbox mode (see
 * priv/playwright/server.exs), so the test-only /test/seed endpoint stages the
 * read-model — no NATS, no harness. The seed records "ship-the-api" (iteration
 * 0 failing, iteration 1 converged) and "fix-the-flaky-test" (a single
 * in-progress iteration — the honest-no-verdict edge case). Run serially
 * because it shares the one read-model.
 */
test.describe.serial("narrative history", () => {
  test("golden path: narrative events render newest-first with a convergence summary", async ({
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
      page.getByRole("heading", { name: "History · ship-the-api" }),
    ).toBeVisible();

    // The plain-language convergence summary leads the view.
    const summary = page.locator("#history-summary");
    await expect(summary).toBeVisible();
    await expect(summary).toHaveAttribute("data-status", "converged");
    await expect(summary).toContainText("This goal converged in 2 iterations");

    // NEWEST-FIRST: iteration 1 is the first event in the timeline.
    const events = page.locator("#timeline li.event");
    await expect(events).toHaveCount(2);
    await expect(events.nth(0)).toHaveAttribute("data-iteration-index", "1");
    await expect(events.nth(1)).toHaveAttribute("data-iteration-index", "0");

    // Narrative format, not raw rows: diff clause + verdict on the judged one.
    await expect(events.nth(0).locator(".narrative")).toContainText(
      "probe flipped fail->pass",
    );
    await expect(events.nth(0).locator(".narrative")).toContainText(
      "-> converged",
    );
    await expect(events.nth(1).locator(".narrative")).toContainText(
      "iteration 0: first observation",
    );

    // The verdict badge marks only the converged event.
    await expect(page.locator("[data-verdict='converged']")).toHaveCount(1);

    // The full predicate vector stays available behind the disclosure.
    await expect(page.locator("#iteration-1-predicate-probe")).toHaveCount(1);
  });

  test("edge case: an in-progress single-iteration goal renders no fabricated verdict", async ({
    page,
    request,
  }) => {
    const seed = await request.post("/test/seed");
    expect(seed.status()).toBe(200);

    await page.goto("/goals/fix-the-flaky-test/history");

    const events = page.locator("#timeline li.event");
    await expect(events).toHaveCount(1);
    await expect(events.nth(0)).toHaveAttribute("data-iteration-index", "0");

    // Honest in-progress state: pending marker, no verdict anywhere.
    await expect(page.locator("[data-pending='true']")).toBeVisible();
    await expect(page.locator("[data-verdict]")).toHaveCount(0);
    await expect(events.nth(0).locator(".narrative")).toContainText(
      "iteration 0: first observation",
    );
    await expect(events.nth(0).locator(".narrative")).not.toContainText(
      "converged",
    );

    // Summary is honest about the unknown total.
    await expect(page.locator("#history-summary")).toHaveAttribute(
      "data-status",
      "in_progress",
    );
    await expect(page.locator("#history-summary")).toContainText(
      "of an unknown total",
    );
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
    await expect(page.locator("#timeline li.event")).toHaveCount(0);
  });
});

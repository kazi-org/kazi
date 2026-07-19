import { test, expect } from "@playwright/test";

/**
 * T3.6b browser certification of the goal board (UC-018).
 *
 * Hermetic: the dashboard server boots in shared-sandbox mode (see
 * priv/playwright/server.exs), so the test-only /test/seed and /test/reset
 * endpoints stage the read-model the board renders — no NATS, no harness. Run
 * serially because both specs mutate the one shared read-model.
 */
test.describe.serial("goal board", () => {
  test("golden path: seeded goals render with status, predicates, iterations", async ({
    page,
    request,
  }) => {
    const seed = await request.post("/test/seed");
    expect(seed.status()).toBe(200);

    await page.goto("/goals");

    await expect(page.locator("#goal-board")).toBeVisible();
    await expect(
      page.getByRole("heading", { name: "kazi goal board" }),
    ).toBeVisible();
    await expect(page.locator("#goals")).toBeVisible();

    // The converged goal: 2/2 predicates, 2 iterations, converged status.
    const converged = page.locator("#goal-ship-the-api");
    await expect(converged).toBeVisible();
    await expect(converged.locator(".goal-ref")).toHaveText("ship-the-api");
    await expect(converged.locator("[data-status]")).toHaveAttribute(
      "data-status",
      "converged",
    );
    await expect(converged.locator(".predicates")).toHaveAttribute(
      "data-predicates",
      "2/2",
    );
    await expect(converged.locator(".iterations")).toHaveAttribute(
      "data-iterations",
      "2",
    );

    // The in-progress goal: 1/2 predicates, 1 iteration.
    const inProgress = page.locator("#goal-fix-the-flaky-test");
    await expect(inProgress).toBeVisible();
    await expect(inProgress.locator("[data-status]")).toHaveAttribute(
      "data-status",
      "in_progress",
    );
    await expect(inProgress.locator(".predicates")).toHaveAttribute(
      "data-predicates",
      "1/2",
    );
    await expect(inProgress.locator(".iterations")).toHaveAttribute(
      "data-iterations",
      "1",
    );
  });

  test("empty state: no goals renders the empty-state message", async ({
    page,
    request,
  }) => {
    const reset = await request.post("/test/reset");
    expect(reset.status()).toBe(200);

    await page.goto("/goals");

    await expect(page.locator("#goal-board")).toBeVisible();
    await expect(page.locator("#goal-board-empty")).toBeVisible();
    await expect(page.locator("#goal-board-empty")).toContainText(
      "No goals yet",
    );
    await expect(page.locator("#goals")).toHaveCount(0);
  });
});

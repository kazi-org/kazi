import { test, expect } from "@playwright/test";

/**
 * T63.9 browser certification of the Mission Control progress-rate panel
 * (IA Q4, UC-061/UC-068, rate-only per ADR-0046): per active goal the panel
 * shows the predicate pass/total RATIO, the red→green flip VELOCITY over recent
 * iterations, and the iteration BUDGET consumed vs cap — and never a fabricated
 * ETA, "estimated", or date-remaining copy.
 *
 * Hermetic: the dashboard boots in shared-sandbox mode (priv/playwright/server.exs,
 * cross-machine fetcher pinned empty). The test-only /test/fleet/seed_progress
 * endpoint stages one running goal with two recorded iterations and a 2-of-10
 * iteration budget — no NATS, no harness.
 */
test.describe.serial("mission control · progress-rate panel", () => {
  test("golden path: ratio, flip velocity, and budget — no ETA copy", async ({
    page,
    request,
  }) => {
    const seed = await request.post("/test/fleet/seed_progress");
    expect(seed.status()).toBe(200);

    await page.goto("/");
    await expect(page.locator("#mission-control")).toBeVisible();

    // The progress-rate panel and the seeded goal's card render.
    const panel = page.locator("#mc-progress");
    await expect(panel).toBeVisible();
    const card = page.locator("#mc-progress-mc-prog-goal");
    await expect(card).toBeVisible();

    // Predicate ratio: 3 of 8 green.
    await expect(card.locator('[data-metric="predicates"] .progval')).toHaveText(
      "3 / 8",
    );
    // Flip velocity: two predicates greened over one transition → 2.0 per iter.
    await expect(
      card.locator('[data-metric="flip-velocity"] .progval'),
    ).toContainText("2.0 /iter");
    await expect(
      card.locator('[data-metric="flip-velocity"] .progval'),
    ).toContainText("red→green");
    // Iteration budget consumed vs cap.
    await expect(card.locator('[data-metric="budget"] .progval')).toHaveText(
      "2 / 10 iterations",
    );

    // ADR-0046 honest-unknown: the panel names no ETA, estimate, or date.
    const panelText = (await panel.innerText()).toLowerCase();
    expect(panelText).not.toContain("eta");
    expect(panelText).not.toContain("estimated");
    expect(panelText).not.toContain("remaining");
    expect(panelText).not.toMatch(/\bdate\b/);
  });
});

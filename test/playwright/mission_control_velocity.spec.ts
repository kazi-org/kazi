import { test, expect } from "@playwright/test";

/**
 * T67.5 browser certification of the Mission Control fleet velocity strip +
 * per-agent drill-in (E67, ADR-0079, rate-only per ADR-0046): the strip shows
 * delivered/day, tokens-per-delivered-task, the fleet stuck RATIO, and the
 * claim→merge lead-time DISTRIBUTION — and never a fabricated ETA or date. The
 * per-agent drill-in NAMES the offending stuck goal.
 *
 * Hermetic: the dashboard boots in shared-sandbox mode (priv/playwright/server.exs,
 * cross-machine fetcher pinned empty). The test-only /test/fleet/seed_velocity
 * endpoint stages two deliveries, one session-counter row, and a terminal stuck
 * run — no NATS, no harness, no real transcripts.
 */
test.describe.serial("mission control · fleet velocity", () => {
  test("golden path: the strip renders and drill-in names a stuck goal", async ({
    page,
    request,
  }) => {
    const seed = await request.post("/test/fleet/seed_velocity");
    expect(seed.status()).toBe(200);

    await page.goto("/");
    await expect(page.locator("#mission-control")).toBeVisible();

    // The velocity strip renders with all four rate/ratio metrics.
    const strip = page.locator("#mc-velocity-strip");
    await expect(strip).toBeVisible();
    await expect(
      strip.locator('[data-velocity-metric="delivered"] .progval'),
    ).toContainText("/day");
    await expect(
      strip.locator('[data-velocity-metric="tokens"] .progval'),
    ).toContainText("tok/task");
    await expect(
      strip.locator('[data-velocity-metric="stuck"] .progval'),
    ).toContainText("stuck");
    await expect(
      page.locator('[data-velocity-metric="lead-time"]'),
    ).toBeVisible();

    // Per-agent drill-in: expanding the agent NAMES its offending stuck goal.
    const agent = page.locator("#mc-velocity-agents details").first();
    await agent.locator("summary").click();
    await expect(
      agent.locator("[data-stuck-goal]"),
    ).toContainText("pw-velo-stuck-goal");

    // ADR-0046 honest-unknown: the panel names no ETA, estimate, or date.
    const panelText = (
      await page.locator("#mc-velocity").innerText()
    ).toLowerCase();
    expect(panelText).not.toContain("eta");
    expect(panelText).not.toContain("estimated");
    expect(panelText).not.toContain("remaining");
    expect(panelText).not.toMatch(/\bdate\b/);
  });

  test("insufficient-data edge: a fresh fleet renders honest 'not enough data yet'", async ({
    page,
    request,
  }) => {
    const reset = await request.post("/test/fleet/reset_velocity");
    expect(reset.status()).toBe(200);

    await page.goto("/");
    await expect(page.locator("#mission-control")).toBeVisible();

    // No strip; the honest empty state instead of zeros pretending to be data.
    await expect(page.locator("#mc-velocity-strip")).toHaveCount(0);
    const empty = page.locator("#mc-velocity-empty");
    await expect(empty).toBeVisible();
    await expect(empty).toContainText("Not enough data yet");
  });
});

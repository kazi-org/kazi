import { test, expect } from "@playwright/test";

/**
 * T63.8 browser certification of the attention fan-in (UC-068): the NEEDS
 * ATTENTION panel composes run-level attention (the ranked queue) with
 * session-level "waiting on you" facts, each entry naming its blocker; clicking
 * a run-attention entry deep-links to that goal's drill-in; an empty fleet shows
 * an honest empty state.
 *
 * Hermetic: the dashboard server boots in shared-sandbox mode (see
 * priv/playwright/server.exs, which pins the remote + waiting sources to empty).
 * The /test/attention/* endpoints stage the run registry + waiting session the
 * panel renders. Run serially because both specs mutate the one shared state.
 */
test.describe.serial("mission control · attention fan-in", () => {
  test("golden path: entries name their blocker and deep-link to the goal", async ({
    page,
    request,
  }) => {
    const seed = await request.post("/test/attention/seed");
    expect(seed.status()).toBe(200);

    await page.goto("/");
    await expect(page.locator("#mc-attention")).toBeVisible();

    // Run-level attention: the stuck run names its failing predicate.
    const stuck = page.locator("#mc-alert-mc-attention-stuck-stuck");
    await expect(stuck).toBeVisible();
    await expect(stuck).toContainText("predicate probe");

    // Session-level attention: the WAITING sub-section names the awaited action.
    await expect(page.locator("#mc-attention-waiting")).toBeVisible();
    const waiting = page.locator("#mc-waiting-pw-sess");
    await expect(waiting).toBeVisible();
    await expect(waiting).toContainText("approve the destructive migration");

    // Clicking the run-attention entry deep-links to that goal's drill-in.
    await stuck.click();
    await expect(page).toHaveURL(/\/goals\/mc-attention-stuck\/drillin$/);
  });

  test("empty state: nothing needs you renders with no attention", async ({
    page,
    request,
  }) => {
    const reset = await request.post("/test/attention/reset");
    expect(reset.status()).toBe(200);

    await page.goto("/");

    await expect(page.locator("#mc-attention")).toBeVisible();
    await expect(page.locator("#mc-attention-empty")).toBeVisible();
    await expect(page.locator("#mc-attention-empty")).toContainText(
      "Nothing needs you right now.",
    );
    await expect(page.locator("#mc-attention-waiting")).toHaveCount(0);
  });
});

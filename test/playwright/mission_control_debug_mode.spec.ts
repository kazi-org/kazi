import { test, expect } from "@playwright/test";

/**
 * T63.7 browser certification of the operator/debug mode split (UC-061,
 * ADR-0078): the dashboard defaults to a calm OPERATOR view with the expert
 * surfaces (DAG, event river, lease map) absent; a DEBUG toggle reveals them,
 * and the choice persists per browser via localStorage.
 *
 * Hermetic: the dashboard server boots in shared-sandbox mode (see
 * priv/playwright/server.exs). No registry seed is needed — the mode split is
 * independent of fleet contents.
 */
test.describe.serial("mission control · operator/debug mode split", () => {
  test("golden path: toggle reveals then hides the expert surfaces", async ({
    page,
  }) => {
    await page.goto("/");
    await expect(page.locator("#mission-control")).toBeVisible();

    // Wait for the main LiveView to JOIN before interacting (a phx patch fired
    // during the join window is lost).
    await page.waitForFunction(() => {
      const ls = (
        window as {
          liveSocket?: {
            isConnected(): boolean;
            main?: { joinCount: number };
          };
        }
      ).liveSocket;
      return !!ls && ls.isConnected() && !!ls.main && ls.main.joinCount > 0;
    });

    // Default: operator mode — no expert surfaces in the DOM.
    await expect(page.locator("#mc-mode")).toHaveAttribute(
      "data-mode",
      "operator",
    );
    await expect(page.locator("#mc-debug-nav")).toHaveCount(0);
    await expect(page.locator("#mc-event-river")).toHaveCount(0);
    await expect(page.locator("#mc-sessions")).toHaveCount(0);

    // Toggle into debug — the three expert surfaces appear.
    await page.locator('#mc-mode a[data-mode-option="debug"]').click();
    await expect(page.locator("#mc-mode")).toHaveAttribute(
      "data-mode",
      "debug",
    );
    await expect(page.locator("#mc-debug-dag")).toBeVisible();
    await expect(page.locator("#mc-debug-leases")).toBeVisible();
    await expect(page.locator("#mc-event-river")).toBeVisible();
    await expect(page.locator("#mc-sessions")).toBeVisible();

    // Toggle back to operator — they disappear again.
    await page.locator('#mc-mode a[data-mode-option="operator"]').click();
    await expect(page.locator("#mc-mode")).toHaveAttribute(
      "data-mode",
      "operator",
    );
    await expect(page.locator("#mc-event-river")).toHaveCount(0);
    await expect(page.locator("#mc-sessions")).toHaveCount(0);
  });

  test("persistence: debug mode survives a bare reload via localStorage", async ({
    page,
  }) => {
    // Enter debug, which mirrors the choice into localStorage.
    await page.goto("/?debug=1");
    await expect(page.locator("#mc-mode")).toHaveAttribute(
      "data-mode",
      "debug",
    );
    await expect(page.locator("#mc-event-river")).toBeVisible();

    // A bare `/` visit (no param) should be restored to debug by the hook.
    await page.goto("/");
    await expect(page.locator("#mc-event-river")).toBeVisible();
    await expect(page.locator("#mc-mode")).toHaveAttribute(
      "data-mode",
      "debug",
    );

    // Clean up so a re-run starts from operator.
    await page.evaluate(() => window.localStorage.removeItem("kazi:mc-debug"));
  });
});

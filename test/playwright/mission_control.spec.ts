import { test, expect } from "@playwright/test";

/**
 * T63.6 browser certification of Mission Control widget direction B (UC-061):
 * project-grouped cards under ruled headers, one relative timestamp per card,
 * and the state/scope/repo/time filters folded into the FLEET header as
 * segmented controls.
 *
 * Hermetic: the dashboard server boots in shared-sandbox mode (see
 * priv/playwright/server.exs, which also pins the cross-machine fetcher to empty
 * so no real daemon injects phantom remote cards). The test-only /test/fleet/*
 * endpoints stage the run registry the grid renders — no NATS, no harness. Run
 * serially because both specs mutate the one shared registry.
 */
test.describe.serial("mission control · widget direction B", () => {
  test("golden path: project-grouped cards, then a state filter regroups them", async ({
    page,
    request,
  }) => {
    const seed = await request.post("/test/fleet/seed");
    expect(seed.status()).toBe(200);

    await page.goto("/");
    await expect(page.locator("#mission-control")).toBeVisible();
    await expect(page.locator("#mc-fleet")).toBeVisible();

    // Wait for the main LiveView to JOIN (not merely for the socket to connect)
    // before interacting: a phx-click fired during the join window is lost and
    // the grid never regroups. joinCount > 0 means the view is mounted and its
    // phx-click handlers are wired.
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

    // Two projects -> two ruled group headers, each naming its org/repo.
    const groups = page.locator(".projgroup-head");
    await expect(groups).toHaveCount(2);
    await expect(
      page.locator('[data-project-group-head="org-alpha/api"]'),
    ).toBeVisible();
    await expect(
      page.locator('[data-project-group-head="org-beta/web"]'),
    ).toBeVisible();

    // The three seeded cards render, grouped under their projects.
    await expect(page.locator("#mc-card-mc-alpha-ship")).toBeVisible();
    await expect(page.locator("#mc-card-mc-alpha-fix")).toBeVisible();
    await expect(page.locator("#mc-card-mc-beta-ship")).toBeVisible();

    // Each card carries exactly one relative timestamp (no AGE/ACTIVE row) and
    // no project badge (provenance lives in the group header now).
    await expect(
      page.locator("#mc-card-mc-alpha-ship .cardtime"),
    ).toHaveCount(1);
    await expect(page.locator(".projbadge")).toHaveCount(0);

    // The state filter is a segmented control in the FLEET header, not the topbar.
    const fleetHeader = page.locator("#mc-fleet .fleethead");
    await expect(fleetHeader.locator(".fleetcontrols")).toBeVisible();
    await expect(fleetHeader.locator("#mc-fleet-chips.segmented")).toBeVisible();

    // Filter by CONVERGED via the segmented control -> the grid regroups to only
    // the converged run, dropping the running cards.
    await page.locator('button[data-count="converged"]').click();
    await expect(page.locator("#mc-card-mc-alpha-ship")).toBeVisible();
    await expect(page.locator("#mc-card-mc-alpha-fix")).toHaveCount(0);
    await expect(page.locator("#mc-card-mc-beta-ship")).toHaveCount(0);
    // Now a single project remains, so no redundant group header survives.
    await expect(page.locator(".projgroup-head")).toHaveCount(0);
  });

  test("edge case: a single-project fleet renders without a group header", async ({
    page,
    request,
  }) => {
    const seed = await request.post("/test/fleet/seed_single");
    expect(seed.status()).toBe(200);

    await page.goto("/");
    await expect(page.locator("#mc-fleet")).toBeVisible();

    // Both cards render...
    await expect(page.locator("#mc-card-mc-solo-a")).toBeVisible();
    await expect(page.locator("#mc-card-mc-solo-b")).toBeVisible();
    // ...under one bare grid with NO ruled project header.
    await expect(page.locator(".projgroup-head")).toHaveCount(0);
    await expect(
      page.locator('[data-project-group="org-solo/app"]'),
    ).toBeVisible();
  });
});

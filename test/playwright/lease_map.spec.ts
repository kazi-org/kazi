import { test, expect } from "@playwright/test";

/**
 * T3.6c browser certification of the presence + lease map (UC-018).
 *
 * Hermetic: the dashboard server boots in shared-sandbox mode and points the
 * lease-map LiveView at an in-memory fixture source (see priv/playwright/server.exs).
 * The test-only /test/leases/seed and /test/leases/release endpoints push snapshots
 * the view renders — no NATS, no transport. Run serially because both specs drive
 * the one shared fixture source.
 */
test.describe.serial("lease map", () => {
  test("golden path: seeded presence + leases render as a list and a map", async ({
    page,
    request,
  }) => {
    const seed = await request.post("/test/leases/seed");
    expect(seed.status()).toBe(200);

    await page.goto("/leases");

    await expect(page.locator("#lease-map")).toBeVisible();
    await expect(
      page.getByRole("heading", { name: "kazi lease map" }),
    ).toBeVisible();

    // Presence list: both instances present, each with its announced intent.
    await expect(page.locator("#presence-list")).toBeVisible();
    await expect(page.locator("#presence-kazi-1")).toBeVisible();
    await expect(page.locator("#presence-kazi-2")).toBeVisible();
    await expect(
      page.locator("#presence-kazi-1 .intent"),
    ).toHaveAttribute("data-intent", "lib-auth");

    // Lease map: each contended resource → its holder.
    await expect(page.locator("#lease-map-table")).toBeVisible();
    await expect(page.locator("#lease-lib-auth .lease-holder")).toHaveAttribute(
      "data-holder",
      "kazi-1",
    );
    await expect(
      page.locator("#lease-lib-billing .lease-holder"),
    ).toHaveAttribute("data-holder", "kazi-2");
  });

  test("a simulated lease release is reflected in the rendered map", async ({
    page,
    request,
  }) => {
    // Seed the populated state and confirm both leases render.
    expect((await request.post("/test/leases/seed")).status()).toBe(200);
    await page.goto("/leases");
    await expect(page.locator("#lease-lib-billing")).toBeVisible();

    // Simulate releasing the billing lease (and kazi-2 leaving): the fixture source
    // now holds the post-release snapshot. The asset-free skeleton renders each
    // mount server-side (no JS bundle / live socket yet — see KaziWeb.Layouts),
    // matching T3.6b's Playwright pattern, so a re-navigation reflects the new
    // snapshot. The websocket-driven LIVE diff (handle_info on a connected mount)
    // is certified by the ExUnit LiveView test.
    expect((await request.post("/test/leases/release")).status()).toBe(200);
    await page.goto("/leases");

    // The billing lease and kazi-2 are gone; the auth lease remains.
    await expect(page.locator("#lease-lib-billing")).toHaveCount(0);
    await expect(page.locator("#presence-kazi-2")).toHaveCount(0);
    await expect(page.locator("#lease-lib-auth")).toBeVisible();
  });
});

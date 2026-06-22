import { test, expect } from "@playwright/test";

/**
 * T3.6a browser smoke test: the supervised dashboard endpoint serves the root
 * LiveView and the liveness probe in a real browser. Hermetic (no NATS/harness).
 */

test("/healthz responds 200 ok", async ({ request }) => {
  const res = await request.get("/healthz");
  expect(res.status()).toBe(200);
  expect(await res.text()).toBe("ok");
});

test("root page renders the dashboard shell", async ({ page }) => {
  await page.goto("/");
  await expect(page).toHaveTitle(/kazi/);
  await expect(page.locator("#dashboard")).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "kazi operator dashboard" }),
  ).toBeVisible();
});

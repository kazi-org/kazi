import { test, expect } from "@playwright/test";
import { INSTALL_CMD, POSITIONING, HERO_TAGLINE, INVOCATION_PHRASE } from "../src/canonical.mjs";

const REPO = "https://github.com/kazi-org/kazi";

// CDN availability is outside the page contract. Serve deterministic empty
// responses for optional remote presentation assets; local assets stay real.
test.beforeEach(async ({ page }) => {
  await page.route(/^https:\/\/(fonts\.googleapis\.com|fonts\.gstatic\.com)\//, route => route.fulfill({ contentType: "text/css", body: "" }));
  await page.route("https://d8j0ntlcm91z4.cloudfront.net/**", route => route.fulfill({ status: 204, body: "" }));
});

test("headline, canonical positioning, and install flow render", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator("h1")).toHaveText(/Done means\s*verified\./);
  await expect(page.getByText(HERO_TAGLINE, { exact: true })).toBeVisible();
  await expect(page.getByText(POSITIONING, { exact: false })).toBeVisible();
  await expect(page.getByText(INVOCATION_PHRASE, { exact: true })).toBeVisible();
  await page.getByRole("link", { name: "Give your agent Kazi" }).click();
  await expect(page).toHaveURL(/#start$/);
  await expect(page.locator("#install-code")).toHaveText(`${INSTALL_CMD}\nkazi install-skill`);
  await expect(page.locator("#plan-code")).toContainText("/kazi plan");
  await expect(page.locator("#apply-code")).toHaveText("/kazi apply");
});

test("copy command writes the exact installation commands", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto("/");
  await page.getByRole("button", { name: "Copy commands", exact: true }).click();
  await expect(page.getByRole("status")).toHaveText("Copied to clipboard");
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(`${INSTALL_CMD}\nkazi install-skill`);
});

test("preserves proof, docs, blog, releases, community and maker links", async ({ page }) => {
  await page.goto("/");
  for (const href of [REPO, "/proof", "/blog", `${REPO}/releases`, `${REPO}/discussions`, `${REPO}/blob/main/docs/concept.md`, "https://ndungu.dev"]) {
    expect(await page.locator(`a[href="${href}"]`).count()).toBeGreaterThan(0);
  }
  await expect(page.locator(".release-label")).toContainText(/v\d+\.\d+\.\d+/);
  await expect(page.locator('link[rel="canonical"]')).toHaveAttribute("href", "https://kazi.sire.run/");
  await expect(page.locator('meta[property="og:image"]')).toHaveAttribute("content", "https://kazi.sire.run/og-image.png");
  await expect(page.locator(".terminal img")).toHaveJSProperty("naturalWidth", 905);
});

test("device appearance switches live between dark and light", async ({ page }) => {
  await page.emulateMedia({ colorScheme: "dark" });
  await page.goto("/");
  await expect(page.locator("body")).toHaveCSS("background-color", "rgb(0, 0, 0)");
  await expect(page.locator("h1")).toHaveCSS("color", "rgb(255, 255, 255)");
  await page.emulateMedia({ colorScheme: "light" });
  await expect(page.locator("body")).toHaveCSS("background-color", "rgb(250, 250, 250)");
  await expect(page.locator("h1")).toHaveCSS("color", "rgb(23, 23, 25)");
  await expect(page.locator(".install")).toHaveCSS("background-color", "rgb(255, 255, 255)");
  await page.emulateMedia({ colorScheme: "dark" });
  await expect(page.locator("body")).toHaveCSS("background-color", "rgb(0, 0, 0)");
});

test("reduced motion hides and pauses the decorative video", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/");
  await expect(page.locator("video")).toBeHidden();
  await expect(page.locator("video")).toHaveJSProperty("paused", true);
  await expect(page.locator("#motion")).toBeHidden();
});

test("mobile navigation opens, closes and reaches installation", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto("/");
  const burger = page.locator(".burger");
  await burger.click();
  await expect(burger).toHaveAttribute("aria-expanded", "true");
  await page.getByRole("navigation", { name: "Mobile navigation" }).getByRole("link", { name: "Get started" }).click();
  await expect(page.locator("#mobile-menu")).toBeHidden();
  await expect(page).toHaveURL(/#start$/);
  await page.goto("/");
  await burger.click();
  await page.keyboard.press("Escape");
  await expect(burger).toBeFocused();
  await expect(page.locator("#mobile-menu")).toBeHidden();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
});

test("page scripts load without runtime errors", async ({ page }) => {
  const errors = [];
  page.on("pageerror", error => errors.push(String(error)));
  await page.goto("/");
  await page.getByText("Is Kazi another coding agent?", { exact: true }).click();
  await expect(page.locator("details[open]")).toContainText("reconciliation controller");
  expect(errors).toEqual([]);
});

test("existing proof gallery keeps reproducible cases", async ({ page }) => {
  await page.goto("/proof");
  await expect(page.getByRole("heading", { name: "Proof, not vibes" })).toBeVisible();
  expect(await page.locator("pre", { hasText: "kazi apply" }).count()).toBeGreaterThanOrEqual(2);
  await expect(page.getByRole("link", { name: /Read the full methodology/ })).toBeVisible();
});

// T9.5 (ADR-0018): Playwright smoke test for the kazi website.
//
// This runs against the BUILT site (site/dist), served by `astro preview`, so a
// broken page (missing hero, wrong install string, dead GitHub link, console
// error) fails CI. Build first: `npm run build`, then `npx playwright test`.
import { defineConfig, devices } from "@playwright/test";

const PORT = 4321;
const BASE_URL = `http://127.0.0.1:${PORT}`;

export default defineConfig({
  testDir: "./tests",
  // Fail the suite (not just the test) if someone leaves a stray test.only.
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : "list",
  use: {
    baseURL: BASE_URL,
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "desktop-chromium",
      use: { ...devices["Desktop Chrome"] },
    },
    {
      name: "mobile-chromium",
      use: { ...devices["Pixel 7"] },
    },
  ],
  // Serve the already-built dist/. `astro preview` is a static server over the
  // build output, so the test exercises the real shipped HTML/JS, not the dev
  // server. Assumes `npm run build` ran first (CI does this explicitly).
  webServer: {
    command: `npm run preview -- --port ${PORT} --host 127.0.0.1`,
    url: BASE_URL,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});

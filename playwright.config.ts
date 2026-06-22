import { defineConfig, devices } from "@playwright/test";

/**
 * Playwright config for the kazi operator dashboard (ADR-0011, T3.6a).
 *
 * Tier-3 browser certification of the LiveView surfaces. The harness is
 * hermetic: it boots the dashboard endpoint in the test env (`MIX_ENV=test`,
 * `server: true`, port 4002 — see config/test.exs) and drives it with Chromium.
 * No NATS and no harness are involved; the skeleton renders from the supervised
 * endpoint alone. T3.6b/c/d add more specs against this same baseURL.
 */
const PORT = 4002;
const baseURL = `http://127.0.0.1:${PORT}`;

export default defineConfig({
  testDir: "./test/playwright",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL,
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
  // Boot the supervised Phoenix endpoint in the test env. `mix run --no-halt`
  // starts the :kazi application (Repo + PubSub + Endpoint) and serves 4002.
  // reuseExistingServer lets a developer keep a server running locally.
  webServer: {
    command: "MIX_ENV=test mix run --no-halt",
    url: `${baseURL}/healthz`,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});

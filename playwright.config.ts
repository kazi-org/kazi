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
// Port is env-overridable (default 4002) so concurrent worktrees on this machine
// can run the browser harness without colliding on the fixed listener. CI leaves
// TEST_HTTP_PORT unset and keeps 4002. The same var is threaded into the server
// command below so the booted endpoint and the browser agree on the port.
const PORT = Number(process.env.TEST_HTTP_PORT ?? 4002);
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
  // Boot the supervised Phoenix endpoint in the test env via the Playwright
  // server script (T3.6b): it starts the :kazi application (Repo + PubSub +
  // Endpoint, serving 4002) and puts the read-model Sandbox in shared mode so the
  // test-only /test/seed + /test/reset endpoints can stage goal-board fixtures
  // that the browser then renders. reuseExistingServer lets a dev keep one up.
  webServer: {
    command: "MIX_ENV=test mix run --no-halt priv/playwright/server.exs",
    url: `${baseURL}/healthz`,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});

// T9.5 (ADR-0018): smoke test for the kazi marketing site (served from dist/).
//
// Asserts the load-bearing surface a visitor must see:
//   - the hero headline,
//   - the real `brew install` command (imported from canonical.mjs, so this
//     test and the page can never silently disagree on the string),
//   - the GitHub repo link,
//   - a mobile-viewport edge case (nav GitHub link + install CTA still render),
//   - no console errors on load.
//
// Run after `npm run build`: `npx playwright test`.
import { test, expect } from "@playwright/test";

import {
  INSTALL_CMD,
  POSITIONING,
  HERO_TAGLINE,
  INVOCATION_PHRASE,
} from "../src/canonical.mjs";

const REPO = "https://github.com/kazi-org/kazi";

// Collect any console.error / pageerror so every test can assert a clean load.
function watchConsole(page) {
  const errors = [];
  page.on("console", (msg) => {
    if (msg.type() === "error") {
      errors.push(msg.text());
    }
  });
  page.on("pageerror", (err) => {
    errors.push(String(err));
  });
  return errors;
}

test.describe("kazi website smoke", () => {
  test("hero headline renders", async ({ page }) => {
    await page.goto("/");
    const h1 = page.locator("h1");
    await expect(h1).toBeVisible();
    // The hero H1 renders the canonical tagline byte-identically (T25.1), so
    // assert the exact decided string rather than fragments.
    await expect(h1).toContainText(HERO_TAGLINE);
    // The positioning one-liner from canonical.mjs (the precise category) is the
    // hero's second beat.
    await expect(page.getByText(POSITIONING)).toBeVisible();
  });

  test("documents the invocation phrase", async ({ page }) => {
    await page.goto("/");
    // T25.6: the decided invocation phrase renders verbatim on the site.
    await expect(page.getByText(INVOCATION_PHRASE)).toBeVisible();
  });

  test("shows the agent-voiced testimonial", async ({ page }) => {
    await page.goto("/");
    // T25.5: the testimonial is present and labelled as agent-authored.
    await expect(page.getByText("What a coding agent says")).toBeVisible();
    await expect(page.getByText(/Agent-authored/)).toBeVisible();
  });

  test("shows the real brew install command", async ({ page }) => {
    await page.goto("/");
    expect(INSTALL_CMD).toBe("brew install kazi-org/tap/kazi");
    // The copy button carries the command in data-cmd AND renders it.
    const copyBtn = page.locator("#copy-install");
    await expect(copyBtn).toHaveAttribute("data-cmd", INSTALL_CMD);
    await expect(copyBtn).toContainText(INSTALL_CMD);
    // It also appears verbatim in the install section's <pre>.
    await expect(page.locator("pre", { hasText: INSTALL_CMD })).toBeVisible();
  });

  test("nav shows a Docs link to the concept doc", async ({ page }) => {
    await page.goto("/");
    // T25.12: the primary nav exposes a Docs entry pointing at concept.md on
    // GitHub (until a rendered /docs exists — the T22.6 decision).
    const docsLink = page
      .getByRole("navigation", { name: "Primary" })
      .getByRole("link", { name: "Docs", exact: true });
    await expect(docsLink).toBeVisible();
    await expect(docsLink).toHaveAttribute(
      "href",
      `${REPO}/blob/main/docs/concept.md`,
    );
  });

  test("footer links to community help (Discussions)", async ({ page }) => {
    await page.goto("/");
    // T25.12: the footer carries a getting-help link to GitHub Discussions.
    const helpLink = page
      .getByRole("contentinfo")
      .getByRole("link", { name: "Discussions", exact: true });
    await expect(helpLink).toBeVisible();
    await expect(helpLink).toHaveAttribute("href", `${REPO}/discussions`);
  });

  test("links to the GitHub repo", async ({ page }) => {
    await page.goto("/");
    const repoLinks = page.locator(`a[href="${REPO}"]`);
    expect(await repoLinks.count()).toBeGreaterThan(0);
    // The nav GitHub button is a concrete, visible entry point.
    await expect(
      page.getByRole("link", { name: "GitHub", exact: true }).first(),
    ).toBeVisible();
  });

  test("loads with no console errors", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto("/", { waitUntil: "networkidle" });
    expect(errors, `console errors on load:\n${errors.join("\n")}`).toEqual([]);
  });
});

// Edge case: on a phone-sized viewport the nav GitHub link and the install CTA
// must still render (the project's mobile-chromium config drives this, but pin
// the viewport explicitly so the intent survives a config change).
test.describe("mobile viewport", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test("nav and install CTA render on a phone", async ({ page }) => {
    const errors = watchConsole(page);
    await page.goto("/", { waitUntil: "networkidle" });

    await expect(
      page.getByRole("link", { name: "GitHub", exact: true }).first(),
    ).toBeVisible();
    await expect(page.locator("#copy-install")).toBeVisible();
    await expect(page.locator("#copy-install")).toContainText(INSTALL_CMD);

    expect(errors, `console errors on mobile load:\n${errors.join("\n")}`).toEqual([]);
  });
});

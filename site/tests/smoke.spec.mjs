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
    // The hero now LEADS with the Claude Code benefit, not the loop category
    // (operator refinement): an explicit "you don't run kazi, Claude does" line.
    await expect(
      page.getByText("You never run kazi yourself — Claude does."),
    ).toBeVisible();
  });

  test("demotes the loop framing into 'How it works'", async ({ page }) => {
    await page.goto("/");
    // The positioning one-liner is the under-the-hood category/mechanic, NOT the
    // opening identity — it lives in the "How it works" section, below the fold,
    // and still appears verbatim (the coherence gate needs it).
    const positioning = page.getByText(POSITIONING);
    await expect(positioning).toBeVisible();
    const posY = await positioning.evaluate(
      (el) => el.getBoundingClientRect().top + window.scrollY,
    );
    const tryY = await page
      .locator("#try")
      .evaluate((el) => el.getBoundingClientRect().top + window.scrollY);
    // It appears AFTER the on-ramp, never as the hero lead.
    expect(posY).toBeGreaterThan(tryY);
  });

  test("documents the invocation phrase", async ({ page }) => {
    await page.goto("/");
    // T25.6: the decided invocation phrase renders verbatim on the site. It now
    // appears in both the hero on-ramp (step 3) and the "you chat with Claude
    // Code" spine section, so assert it is present at least once.
    await expect(page.getByText(INVOCATION_PHRASE).first()).toBeVisible();
  });

  test("hero leads with the 10-second on-ramp (T25.4)", async ({ page }) => {
    await page.goto("/");
    // The FIRST screen is the agent on-ramp: a "Try it in 10 seconds" block that
    // walks install -> install-skill -> the invocation phrase. install-skill is
    // the human's primary path (the raw CLI is demoted to a Reference section).
    await expect(
      page.getByRole("heading", { name: "Try it in 10 seconds" }),
    ).toBeVisible();
    await expect(page.getByText("kazi install-skill").first()).toBeVisible();
    // The on-ramp sits ABOVE the "How it works" reconcile-loop mechanic.
    const tryY = await page
      .locator("#try")
      .evaluate((el) => el.getBoundingClientRect().top + window.scrollY);
    const howY = await page
      .locator("#how")
      .evaluate((el) => el.getBoundingClientRect().top + window.scrollY);
    expect(tryY).toBeLessThan(howY);
  });

  test("has the 'you chat with Claude Code, it drives kazi' spine", async ({
    page,
  }) => {
    await page.goto("/");
    // T25.4 / T25.9 spine: the primary section frames the human -> Claude -> kazi
    // -> Claude flow; kazi is the loop the agent drives, never called "a skill".
    await expect(
      page.getByRole("heading", {
        name: "You chat with Claude Code, it drives kazi",
      }),
    ).toBeVisible();
  });

  test("demotes the raw CLI to a Reference section", async ({ page }) => {
    await page.goto("/");
    // The raw `kazi` verbs are the agent/advanced path, not the human's primary
    // one — they live under a Reference heading below the on-ramp.
    await expect(
      page.getByRole("heading", { name: "Reference: drive kazi directly" }),
    ).toBeVisible();
  });

  test("shows the agent-voiced testimonial", async ({ page }) => {
    await page.goto("/");
    // T25.5: the testimonial is present and labelled as agent-authored.
    await expect(page.getByText("What a coding agent says")).toBeVisible();
    await expect(page.getByText(/Agent-authored/)).toBeVisible();
  });

  test("shows the in-family token-economy section", async ({ page }) => {
    await page.goto("/");
    // T25.11 (ADR-0033/0035): the token-economy section leads with in-family
    // Claude tiering — a cheap-model grind, no local model required.
    await expect(
      page.getByRole("heading", { name: "Token economy without local models" }),
    ).toBeVisible();
    // The worked example shows `kazi apply --harness claude --model <cheap-id>`.
    await expect(
      page.locator("pre", { hasText: "--harness claude --model claude-haiku-4-5" }),
    ).toBeVisible();
    // And the escalate-on-stuck ladder is documented.
    await expect(
      page.locator("pre", { hasText: "claude-opus-4-8" }),
    ).toBeVisible();
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

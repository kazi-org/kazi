#!/usr/bin/env node
// playwright_runner.js — the real browser runner for Kazi.Providers.Browser
// (T2.2, UC-012).
//
// This is the genuine production runner the `:browser` predicate provider drives
// via System.cmd (Port/subprocess). It is NOT a stub: kazi is Elixir, Playwright
// is JavaScript, so the live-UI proof lives here. The provider passes a JSON
// instruction payload as the last CLI argument; this script launches a real
// Chromium, navigates to the URL, replays the interaction steps, evaluates the
// assertions, optionally captures a screenshot, and prints exactly one JSON
// result object to stdout for the provider to interpret.
//
// Real use requires the runtime deps installed once (alongside this app or in
// the target workspace):
//
//     npm i playwright && npx playwright install chromium
//
// Output contract (single JSON object on stdout):
//   { "status": "pass" | "fail" | "error",
//     "url": "<url>",
//     "assertions": [ { "type", "selector"?, "ok", "expected"?, "found"? } ],
//     "screenshot": "<path>" | null,
//     "error": "<message>" | null }
//
// Assertion types dispatch through the ASSERTIONS table below (T43.1, ADR-0053
// §1). The runner — not kazi core — owns the assertion vocabulary: config is
// passed verbatim from the predicate, so adding a type is a change here plus a
// schema/loader entry, never a change to the controller (the ADR-0040 dividend).
// To add one, add an entry to ASSERTIONS returning the same
// `{type, ok, expected, found}` record shape, then extend
// `@browser_assertion_types` in lib/kazi/goal/loader.ex and the `browser` schema
// in lib/kazi/predicate/schema.ex.
//
// Exit code is 0 whenever a JSON verdict was produced (including a "fail"); a
// non-zero exit is reserved for the runner being unable to produce any verdict
// (e.g. Playwright not installed), which the provider maps to :error.

"use strict";

function emit(result) {
  process.stdout.write(JSON.stringify(result) + "\n");
}

function readPayload() {
  // The provider passes the JSON payload as the last positional argument.
  const raw = process.argv[process.argv.length - 1];
  return JSON.parse(raw);
}

async function applyStep(page, step, timeout) {
  switch (step.action) {
    case "click":
      return page.click(step.selector, { timeout });
    case "fill":
      return page.fill(step.selector, step.value ?? "", { timeout });
    case "press":
      return page.press(step.selector, step.key, { timeout });
    case "wait_for":
      return page.waitForSelector(step.selector, { timeout });
    case "goto":
      return page.goto(step.url, { timeout, waitUntil: "load" });
    default:
      throw new Error(`unknown step action: ${step.action}`);
  }
}

// --- Journey capture -------------------------------------------------------
//
// Attached to the page BEFORE the first navigation so the record spans the whole
// journey (initial load + every step), not just the state at assert time. A
// console error raised during step 3 and cleared by step 4 still counts: the
// journey produced it. Capture is unconditional and cheap; `console_clean`
// decides at assert time which buckets it reads.

function captureJourney(page) {
  const captured = { consoleErrors: [], networkFailures: [] };

  page.on("console", (msg) => {
    if (msg.type() !== "error") return;
    const loc = msg.location();
    captured.consoleErrors.push({
      kind: "console.error",
      text: msg.text(),
      location: loc && loc.url ? `${loc.url}:${loc.lineNumber}:${loc.columnNumber}` : null,
    });
  });

  page.on("response", (response) => {
    const status = response.status();
    if (status < 400) return;
    captured.networkFailures.push({
      kind: "network",
      status,
      url: response.url(),
    });
  });

  return captured;
}

// --- Assertion dispatch table ----------------------------------------------
//
// type -> async ({ page, assertion, timeout, captured }) => { ok, expected, found }
// The caller merges `{type, selector}` in, so each entry returns only its verdict.

const ASSERTIONS = {
  visible: async ({ page, assertion, timeout }) => {
    const visible = await page
      .waitForSelector(assertion.selector, { state: "visible", timeout })
      .then(() => true)
      .catch(() => false);
    return { ok: visible, expected: "visible", found: visible ? "visible" : "not visible" };
  },

  hidden: async ({ page, assertion, timeout }) => {
    const hidden = await page
      .waitForSelector(assertion.selector, { state: "hidden", timeout })
      .then(() => true)
      .catch(() => false);
    return { ok: hidden, expected: "hidden", found: hidden ? "hidden" : "visible" };
  },

  text: async ({ page, assertion, timeout }) => {
    const text = await page.textContent(assertion.selector, { timeout }).catch(() => null);
    const found = text == null ? "" : text.trim();
    const ok =
      assertion.exact != null
        ? found === assertion.exact
        : (found || "").includes(assertion.contains ?? "");
    return {
      ok,
      expected: assertion.exact != null ? assertion.exact : assertion.contains,
      found,
    };
  },

  url: async ({ page, assertion }) => {
    const current = page.url();
    const ok = assertion.contains
      ? current.includes(assertion.contains)
      : current === assertion.exact;
    return { ok, expected: assertion.exact ?? assertion.contains, found: current };
  },

  // The journey produced zero console.error — and, with `network: true`, no
  // failed 4xx/5xx response either (T43.1, ADR-0053 §1). `found` is the list of
  // offenders (the evidence a fixer agent needs to locate them), so `expected: 0`
  // vs `found.length` reads as a count comparison. A captured error is a real
  // :fail: the page ran and misbehaved.
  console_clean: async ({ assertion, captured }) => {
    const found = captured.consoleErrors.concat(
      assertion.network ? captured.networkFailures : []
    );
    return { ok: found.length === 0, expected: 0, found };
  },
};

async function evalAssertion(page, assertion, timeout, captured) {
  const base = { type: assertion.type, selector: assertion.selector };
  const handler = ASSERTIONS[assertion.type];

  if (!handler) {
    return { ...base, ok: false, expected: "known assertion type", found: assertion.type };
  }

  return { ...base, ...(await handler({ page, assertion, timeout, captured })) };
}

async function main() {
  let payload;
  try {
    payload = readPayload();
  } catch (e) {
    emit({ status: "error", url: null, assertions: [], screenshot: null, error: `bad payload: ${e.message}` });
    process.exit(0);
  }

  const timeout = payload.timeout_ms ?? 30000;

  let chromium;
  try {
    ({ chromium } = require("playwright"));
  } catch (e) {
    // Playwright not installed: the runner cannot produce a verdict. Non-zero
    // exit so the provider maps this to :error (infra), not a UI :fail.
    process.stderr.write(`playwright not available: ${e.message}\n`);
    process.exit(2);
  }

  let browser;
  try {
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage();
    // Listeners BEFORE the first navigation: `console_clean` asserts over the
    // whole journey, so the initial load's errors must be in the record too.
    const captured = captureJourney(page);
    await page.goto(payload.url, { timeout, waitUntil: "load" });

    for (const step of payload.steps || []) {
      await applyStep(page, step, timeout);
    }

    const assertions = [];
    for (const assertion of payload.assertions || []) {
      assertions.push(await evalAssertion(page, assertion, timeout, captured));
    }

    let screenshot = null;
    if (payload.screenshot) {
      await page.screenshot({ path: payload.screenshot, fullPage: true });
      screenshot = payload.screenshot;
    }

    const allOk = assertions.every((a) => a.ok);
    emit({
      status: allOk ? "pass" : "fail",
      url: payload.url,
      assertions,
      screenshot,
      error: null,
    });
  } catch (e) {
    // A launch/navigation/timeout failure means we could not evaluate the UI:
    // report status "error" (the provider treats it as infra, not failing work).
    emit({
      status: "error",
      url: payload.url,
      assertions: [],
      screenshot: null,
      error: e.message,
    });
  } finally {
    if (browser) await browser.close().catch(() => {});
  }
}

main();

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
  const captured = { consoleErrors: [], networkFailures: [], downloads: [] };

  // T49.10 (ADR-0064 d7): downloads are captured for the SAME reason console
  // errors are — assertions run AFTER every step, so a download triggered by
  // step 3 has already finished by assert time. A bare `waitForEvent('download')`
  // at assert time would wait for a SECOND download that never comes and report
  // a false `ok:false`. The Download objects are stashed cheaply here; the
  // expensive part (resolving the saved path, hashing it) is deferred to the
  // `download` assertion, which only runs if a goal asked for one.
  page.on("download", (download) => captured.downloads.push(download));

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

  // T49.10 (ADR-0064 d7): the file-effect assertion — the journey actually
  // produced a download whose filename matches `filename_pattern`. `found` is
  // `{filename, sha256, path}` so a fixer agent gets the file's identity, not
  // just a boolean; the sha256 is what makes "the RIGHT file" checkable rather
  // than "a file with the right name".
  //
  // Two ways a download arrives, and both must work:
  //
  //   * `trigger_selector` given — arm the wait BEFORE the click, via
  //     Promise.all. Clicking first and then waiting races the event: a fast
  //     download fires before the listener attaches and is missed forever.
  //   * no `trigger_selector` — an earlier STEP triggered it, so it is already
  //     in `captured.downloads` (see captureJourney). Only if none was captured
  //     do we wait, for one still in flight.
  //
  // No download within the timeout is a real `:fail` (the UI did not do the
  // work), never an `:error` — the page ran, it just did not deliver the file.
  download: async ({ page, assertion, timeout, captured }) => {
    const timeoutMs = assertion.timeout_ms ?? timeout;
    const expected = assertion.filename_pattern;

    let download = null;
    try {
      if (assertion.trigger_selector) {
        // Arm the listener BEFORE the click — this ordering is the whole point.
        const [d] = await Promise.all([
          page.waitForEvent("download", { timeout: timeoutMs }),
          page.click(assertion.trigger_selector, { timeout: timeoutMs }),
        ]);
        download = d;
      } else {
        download =
          captured.downloads.shift() ??
          (await page.waitForEvent("download", { timeout: timeoutMs }));
      }
    } catch (e) {
      // Timeout (or a missing trigger selector): the journey produced no
      // download. Real failing work.
      return { ok: false, expected, found: null };
    }

    const filename = download.suggestedFilename();
    let path = null;
    let sha256 = null;
    try {
      path = await download.path();
      if (path) {
        const crypto = require("crypto");
        const fs = require("fs");
        sha256 = crypto.createHash("sha256").update(fs.readFileSync(path)).digest("hex");
      }
    } catch (e) {
      // The file could not be read back (a failed/cancelled download). Report
      // what we know rather than throwing: the filename still identifies it.
      path = null;
    }

    // The pattern is a regex source string, matched against the suggested
    // filename. An invalid pattern is the goal author's error, and is reported
    // as a failing assertion naming the bad pattern — not an :error, and never
    // a silent pass.
    let ok;
    try {
      ok = new RegExp(expected).test(filename);
    } catch (e) {
      return {
        ok: false,
        expected: `valid filename_pattern regex, got ${JSON.stringify(expected)}`,
        found: { filename, sha256, path },
      };
    }

    return { ok, expected, found: { filename, sha256, path } };
  },

  // Accessibility: run axe-core against the current view and assert at most
  // `max_violations` (default 0) violations at or above `severity` (default
  // "serious", T43.2 / UC-056). axe-core is a RUNNER-SIDE OPTIONAL dependency
  // (Node/JS side, not an Elixir dep). When it is absent the assertion is
  // UNAVAILABLE, promoted to an overall run `status: "error"` in main() — the
  // provider maps that to :error, NEVER :fail: a missing evidence tool is infra,
  // not failing UI work. `found` lists each violation's rule id + impact + the
  // node targets (the evidence a fixer needs); `count` is the violation count the
  // provider surfaces as an envelope-v2 score (lower_better, ADR-0041).
  a11y: async ({ page, assertion }) => {
    let axeSource;
    try {
      axeSource = require("axe-core").source;
    } catch (e) {
      return { unavailable: true, ok: false, expected: null, found: [], error: "a11y unavailable" };
    }

    const maxViolations = assertion.max_violations ?? 0;
    const severity = assertion.severity ?? "serious";
    const rank = { minor: 0, moderate: 1, serious: 2, critical: 3 };
    const threshold = rank[severity] ?? rank.serious;

    await page.evaluate(axeSource);
    const results = await page.evaluate(async () => await window.axe.run(document));

    const found = (results.violations || [])
      .filter((v) => (rank[v.impact] ?? 0) >= threshold)
      .map((v) => ({
        id: v.id,
        impact: v.impact,
        nodes: (v.nodes || []).map((n) => (n.target || []).join(" ")),
      }));

    return { ok: found.length <= maxViolations, expected: maxViolations, found, count: found.length };
  },
};

// --- Viewports (T43.5, ADR-0053) -------------------------------------------
//
// `viewport` runs the WHOLE journey at each named width — not just the
// assertions. Layout drives behaviour: a nav collapses to a burger on mobile, so
// a `click` step that works at 1440px misses at 390px. Asserting at a different
// width than you navigated at would prove nothing.
//
// The named sizes are conventional device classes, stated once here so a goal
// says `viewport = ["mobile", "desktop"]` rather than carrying pixel counts.
// `{width, height}` stays available for anything specific.
const NAMED_VIEWPORTS = {
  mobile: { width: 390, height: 844 },
  tablet: { width: 820, height: 1180 },
  desktop: { width: 1440, height: 900 },
};

// Normalize `viewport` to a list of `{label, size}`. ABSENT yields `[null]` —
// one journey with no setViewportSize call, byte-identical to pre-T43.5
// behaviour, which is what keeps every existing goal-file unaffected.
function resolveViewports(viewport) {
  if (viewport == null) return [null];
  const list = Array.isArray(viewport) ? viewport : [viewport];
  if (list.length === 0) return [null];

  return list.map((v) => {
    if (typeof v === "string") {
      const size = NAMED_VIEWPORTS[v];
      if (!size) {
        throw new Error(
          `unknown viewport ${JSON.stringify(v)} (known: ${Object.keys(NAMED_VIEWPORTS).join(", ")}, or {width, height})`
        );
      }
      return { label: v, size };
    }
    if (v && typeof v.width === "number" && typeof v.height === "number") {
      return { label: `${v.width}x${v.height}`, size: { width: v.width, height: v.height } };
    }
    throw new Error(`bad viewport ${JSON.stringify(v)} (want a name or {width, height})`);
  });
}

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

    // T43.5: one journey per viewport, each on a FRESH page. A fresh page per
    // width is deliberate — `console_clean` asserts over "the journey", and
    // replaying steps on a reused page would fold the desktop pass's errors into
    // the mobile one's record.
    const viewports = resolveViewports(payload.viewport);
    const assertions = [];
    let screenshot = null;

    for (const vp of viewports) {
      // `acceptDownloads` is Playwright's default, but the `download` assertion
      // (T49.10) depends on it entirely — a context that refuses downloads makes
      // that assertion fail for a reason no evidence would explain. Stated
      // explicitly so the dependency is visible and version-proof.
      const page = await browser.newPage({ acceptDownloads: true });
      if (vp) await page.setViewportSize(vp.size);

      // Listeners BEFORE the first navigation: `console_clean` asserts over the
      // whole journey, so the initial load's errors must be in the record too.
      const captured = captureJourney(page);
      await page.goto(payload.url, { timeout, waitUntil: "load" });

      for (const step of payload.steps || []) {
        await applyStep(page, step, timeout);
      }

      for (const assertion of payload.assertions || []) {
        const record = await evalAssertion(page, assertion, timeout, captured);
        // The viewport label rides on the record so a failing check NAMES the
        // width it failed at — "text failed" is not actionable when the same
        // assertion passed at 1440px and failed at 390px.
        assertions.push(vp ? { ...record, viewport: vp.label } : record);
      }

      if (payload.screenshot) {
        // Multi-viewport runs would clobber one path, so suffix per width. A
        // single (or absent) viewport keeps the exact path the caller asked for.
        const path =
          viewports.length > 1 && vp
            ? payload.screenshot.replace(/(\.[a-z]+)?$/i, `-${vp.label}$1`)
            : payload.screenshot;
        await page.screenshot({ path, fullPage: true });
        screenshot = screenshot ? `${screenshot},${path}` : path;
      }

      await page.close().catch(() => {});
    }

    // An UNAVAILABLE assertion (e.g. a11y with axe-core not installed on the
    // runner side) means we could not evaluate that check at all — promote the
    // whole run to "error" so the provider maps it to :error (infra), never a UI
    // :fail. The evidence still carries the per-assertion records.
    const unavailable = assertions.find((a) => a.unavailable);
    if (unavailable) {
      emit({
        status: "error",
        url: payload.url,
        assertions,
        screenshot,
        error: unavailable.error || "assertion unavailable",
      });
    } else {
      const allOk = assertions.every((a) => a.ok);
      emit({
        status: allOk ? "pass" : "fail",
        url: payload.url,
        assertions,
        screenshot,
        error: null,
      });
    }
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

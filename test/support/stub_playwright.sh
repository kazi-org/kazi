#!/usr/bin/env bash
# Stub that emulates the Node Playwright runner for Tier-2 boundary tests of
# Kazi.Providers.Browser. It is NOT a lib/ stub (zero-stub policy applies to
# lib/ only) — it is a real external program the provider shells out to via
# System.cmd, exercising the genuine subprocess boundary WITHOUT launching a
# real browser, so `mix test` stays hermetic on a browser-less CI.
#
# The real runner (priv/browser/playwright_runner.js) reads a JSON payload as its
# last positional argument and prints one JSON verdict to stdout; this stub
# mirrors that contract. What it prints is driven by env vars the test sets via
# the provider's `:env` config seam (the same seam ProdLog/TestRunner expose):
#
#   * STUB_JSON  — the exact JSON line to print as the verdict (highest priority).
#   * STUB_EXIT  — the exit code (default 0). A non-zero exit emulates the runner
#     being unable to produce a verdict (e.g. Playwright not installed), which
#     the provider must map to :error.
#   * STUB_NOISE — if set, printed as a leading non-JSON line before the verdict,
#     proving the provider tolerates diagnostic noise before the JSON object.
#
# It also echoes the received payload to stderr (folded into stdout is avoided so
# it does not pollute the JSON parse) is intentionally NOT done — keeping stdout
# to just the (optional noise +) verdict mirrors the real runner's stdout shape.
set -euo pipefail

if [ -n "${STUB_NOISE:-}" ]; then
  echo "${STUB_NOISE}"
fi

if [ -n "${STUB_JSON:-}" ]; then
  echo "${STUB_JSON}"
fi

exit "${STUB_EXIT:-0}"

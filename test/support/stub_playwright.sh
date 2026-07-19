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
#   * STUB_SEQ_FILE — a file with one JSON verdict per line. Each invocation prints
#     the NEXT line (tracked in <STUB_SEQ_FILE>.counter), so a synthetic-journey
#     monitor that re-runs the runner N times sees a controlled SEQUENCE of
#     verdicts (T32.10). Takes priority over STUB_JSON when set.
#
# It also echoes the received payload to stderr (folded into stdout is avoided so
# it does not pollute the JSON parse) is intentionally NOT done — keeping stdout
# to just the (optional noise +) verdict mirrors the real runner's stdout shape.
set -euo pipefail

if [ -n "${STUB_NOISE:-}" ]; then
  echo "${STUB_NOISE}"
fi

if [ -n "${STUB_SEQ_FILE:-}" ]; then
  counter_file="${STUB_SEQ_FILE}.counter"
  n=0
  if [ -f "$counter_file" ]; then n=$(cat "$counter_file"); fi
  # sed is 1-indexed; print the (n+1)th verdict line, then advance the counter.
  sed -n "$((n + 1))p" "$STUB_SEQ_FILE"
  echo "$((n + 1))" > "$counter_file"
  exit "${STUB_EXIT:-0}"
fi

if [ -n "${STUB_JSON:-}" ]; then
  echo "${STUB_JSON}"
fi

exit "${STUB_EXIT:-0}"

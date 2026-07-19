#!/usr/bin/env bash
# Stub that emulates `claude -p --output-format json` for Tier-2 boundary tests
# of Kazi.Harness.ClaudeAdapter's JSON parsing (T4.1). Like stub_claude.sh it is
# NOT a lib/ stub (zero-stub policy applies to lib/ only) — it is a real external
# binary the adapter shells out to, exercising the genuine System.cmd boundary
# and the JSON-envelope parse path end to end.
#
# Behaviour:
#   * Writes a marker file into the CURRENT WORKING DIRECTORY (proving the
#     adapter ran the harness in the target workspace, so edits land in place).
#   * Emits a representative `claude` JSON result envelope on stdout: a `result`
#     text, a `usage` object (input/output/cache token components), a
#     `total_cost_usd`, and a `touched` working set — the structured fields the
#     adapter parses and feeds into the budget.
#   * The token/cost numbers are overridable via env so a test can assert an
#     EXACT total the budget then consumes:
#       STUB_INPUT_TOKENS, STUB_OUTPUT_TOKENS, STUB_CACHE_READ_TOKENS,
#       STUB_CACHE_CREATION_TOKENS, STUB_COST_USD.
#   * Exit code is controlled by STUB_EXIT (default 0).
set -euo pipefail

# Prove edits land in the workspace: write into the cwd System.cmd set via `cd:`.
echo "edited-by-stub" > stub_edit.txt

input_tokens="${STUB_INPUT_TOKENS:-100}"
output_tokens="${STUB_OUTPUT_TOKENS:-250}"
cache_read="${STUB_CACHE_READ_TOKENS:-5000}"
cache_creation="${STUB_CACHE_CREATION_TOKENS:-0}"
cost_usd="${STUB_COST_USD:-0.0123}"

cat <<JSON
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "duration_ms": 4242,
  "num_turns": 3,
  "result": "Made the failing unit test pass.",
  "session_id": "stub-session-0001",
  "total_cost_usd": ${cost_usd},
  "usage": {
    "input_tokens": ${input_tokens},
    "output_tokens": ${output_tokens},
    "cache_creation_input_tokens": ${cache_creation},
    "cache_read_input_tokens": ${cache_read}
  },
  "touched": ["lib/app/widget.ex", "test/app/widget_test.exs"]
}
JSON

exit "${STUB_EXIT:-0}"

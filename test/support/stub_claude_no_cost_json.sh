#!/usr/bin/env bash
# Stub emulating a harness that reports a `usage` token split but NO dollar
# figure (no `total_cost_usd`) — the case T34.5's price-map fallback exists for.
# Like the other stub_*.sh, this is a real external binary (zero-stub policy
# applies to lib/ only), exercising the genuine System.cmd + JSON-parse path so
# Kazi.Harness.CliAdapter must derive `cost_usd` from the dated price map.
#
# Token counts are overridable so a test can assert an EXACT computed cost:
#   STUB_INPUT_TOKENS, STUB_OUTPUT_TOKENS, STUB_CACHE_READ_TOKENS,
#   STUB_CACHE_CREATION_TOKENS. Exit code via STUB_EXIT (default 0).
set -euo pipefail

# Prove edits land in the workspace cwd System.cmd set via `cd:`.
echo "edited-by-stub" > stub_edit.txt

input_tokens="${STUB_INPUT_TOKENS:-100}"
output_tokens="${STUB_OUTPUT_TOKENS:-250}"
cache_read="${STUB_CACHE_READ_TOKENS:-5000}"
cache_creation="${STUB_CACHE_CREATION_TOKENS:-0}"

cat <<JSON
{
  "type": "result",
  "subtype": "success",
  "is_error": false,
  "result": "Made the failing unit test pass.",
  "session_id": "stub-session-no-cost",
  "usage": {
    "input_tokens": ${input_tokens},
    "output_tokens": ${output_tokens},
    "cache_creation_input_tokens": ${cache_creation},
    "cache_read_input_tokens": ${cache_read}
  },
  "touched": ["lib/app/widget.ex"]
}
JSON

exit "${STUB_EXIT:-0}"

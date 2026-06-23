#!/usr/bin/env bash
# Stub that emulates `opencode run <prompt> --format json` for Tier-2 boundary
# tests of the :opencode harness profile (T8.4, ADR-0016). Like stub_claude_json.sh
# it is NOT a lib/ stub (the zero-stub policy applies to lib/ only) — it is a real
# external binary that exercises the genuine subprocess + NDJSON-parse path end to
# end.
#
# Behaviour:
#   * Writes a marker file into the CURRENT WORKING DIRECTORY (proving the harness
#     ran in the target workspace, so edits land in place).
#   * Emits a REPRESENTATIVE opencode `--format json` event stream on stdout as
#     NDJSON — one JSON object per line, NOT a single envelope. The shape mirrors
#     opencode v1.17.9's real MessageV2 server-bus events (grounded in the
#     installed binary's embedded schemas + one live `step_start` capture):
#       - message.part.updated with a step-start part
#       - message.part.updated with the assistant TEXT part (the final result)
#       - message.updated with the assistant message `info`, carrying the
#         `tokens` object ({input, output, reasoning, cache:{read, write}}) and a
#         USD `cost`.
#   * Token/cost numbers are overridable via env so a test can assert an EXACT
#     total the budget then consumes:
#       STUB_INPUT_TOKENS, STUB_OUTPUT_TOKENS, STUB_REASONING_TOKENS,
#       STUB_CACHE_READ_TOKENS, STUB_CACHE_WRITE_TOKENS, STUB_COST_USD.
#     Set STUB_NO_USAGE=1 to omit the usage/cost event entirely (modelling a
#     harness run that reported no usage — the budget then degrades to an estimate).
#   * Exit code is controlled by STUB_EXIT (default 0).
set -euo pipefail

# Prove edits land in the workspace: write into the cwd System.cmd set via `cd:`.
echo "edited-by-opencode-stub" > stub_edit.txt

input_tokens="${STUB_INPUT_TOKENS:-120}"
output_tokens="${STUB_OUTPUT_TOKENS:-340}"
reasoning_tokens="${STUB_REASONING_TOKENS:-40}"
cache_read="${STUB_CACHE_READ_TOKENS:-900}"
cache_write="${STUB_CACHE_WRITE_TOKENS:-0}"
cost_usd="${STUB_COST_USD:-0.0042}"

# Event 1: a step-start part (no usable text/usage — exercises the skip path).
echo '{"type":"message.part.updated","properties":{"part":{"id":"prt_step","messageID":"msg_a","sessionID":"ses_a","type":"step-start"}}}'

# Event 2: the assistant TEXT part — this text is the final :result.
echo '{"type":"message.part.updated","properties":{"part":{"id":"prt_text","messageID":"msg_a","sessionID":"ses_a","type":"text","text":"Made the failing unit test pass."}}}'

# Event 3: the assistant message info, carrying tokens + cost (unless suppressed).
if [ "${STUB_NO_USAGE:-0}" != "1" ]; then
  cat <<JSON
{"type":"message.updated","properties":{"info":{"id":"msg_a","role":"assistant","sessionID":"ses_a","modelID":"qwen3.6:35b-a3b-q8_0","providerID":"dgx-ollama","cost":${cost_usd},"tokens":{"input":${input_tokens},"output":${output_tokens},"reasoning":${reasoning_tokens},"cache":{"read":${cache_read},"write":${cache_write}}}}}}
JSON
fi

# Non-TTY plain-text echo of the final part (opencode does this); the parser must
# skip this non-JSON line gracefully.
echo "Made the failing unit test pass."

exit "${STUB_EXIT:-0}"

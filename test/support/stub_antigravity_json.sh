#!/usr/bin/env bash
# Stub that emulates `antigravity run --prompt-file <tmp> --output json --yes`
# for the Tier-2 boundary test of the :antigravity harness profile (T14.3,
# ADR-0022). Like the other stubs it is NOT a lib/ stub (the zero-stub policy
# applies to lib/ only) — it is a real external binary that exercises the genuine
# subprocess + prompt-file + JSON-parse path end to end.
#
# It proves the CliAdapter's `prompt_via: :file` seam: the adapter must have
# written the prompt to the temp file named by --prompt-file, in this stub's cwd
# (the workspace). The stub:
#
#   * Parses out the --prompt-file path, asserting the file EXISTS and is readable
#     (the #76 workaround: the prompt travels via the file, never bare -p which
#     would drop stdout under this very non-TTY subprocess). It records the file's
#     contents to `seen_prompt.txt` and the full argv to `harness_argv.txt` in the
#     cwd so the test can inspect both.
#   * Emits a REPRESENTATIVE Antigravity `--output json` envelope on stdout: a
#     single JSON object with `result` and a `usage` block. Token/cost numbers are
#     overridable via env so a test can assert an EXACT total the budget consumes:
#       STUB_INPUT_TOKENS, STUB_OUTPUT_TOKENS.
#     Set STUB_NO_USAGE=1 to omit the usage block (the budget then estimates).
#   * Exit code is controlled by STUB_EXIT (default 0).
set -euo pipefail

# Record the full argv (one per line) so the test can assert the workaround shape.
printf '%s\n' "$@" > harness_argv.txt

# Extract the --prompt-file path.
prompt_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prompt-file)
      prompt_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [ -z "$prompt_file" ] || [ ! -f "$prompt_file" ]; then
  echo "stub_antigravity: --prompt-file path missing or not a file: '$prompt_file'" >&2
  exit 3
fi

# Record what the prompt file actually contained (proving the adapter wrote it).
cat "$prompt_file" > seen_prompt.txt

input_tokens="${STUB_INPUT_TOKENS:-1500}"
output_tokens="${STUB_OUTPUT_TOKENS:-400}"

if [ "${STUB_NO_USAGE:-0}" = "1" ]; then
  printf '{"type":"result","result":"Made the failing unit test pass."}\n'
else
  total=$((input_tokens + output_tokens))
  printf '{"type":"result","result":"Made the failing unit test pass.","usage":{"input_tokens":%s,"output_tokens":%s,"total_tokens":%s}}\n' \
    "$input_tokens" "$output_tokens" "$total"
fi

exit "${STUB_EXIT:-0}"

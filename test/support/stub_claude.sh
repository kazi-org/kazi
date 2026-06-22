#!/usr/bin/env bash
# Stub that emulates `claude -p` for Tier-2 boundary tests of
# Kazi.Harness.ClaudeAdapter. It is NOT a lib/ stub (zero-stub policy applies to
# lib/ only) — it is a real external binary the adapter shells out to, exercising
# the genuine System.cmd boundary.
#
# Behaviour:
#   * Echoes the prompt it received (the args after `-p`) to stdout, so the test
#     can assert the failing-predicate evidence reached the harness.
#   * Writes a marker file into the CURRENT WORKING DIRECTORY (proving the
#     adapter ran the harness in the target workspace, so edits land in place).
#   * Exit code is controlled by STUB_EXIT (default 0) so tests can drive the
#     non-zero path.
set -euo pipefail

# Find the prompt: the argument following `-p`.
prompt=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-p" ]; then
    prompt="$arg"
    break
  fi
  prev="$arg"
done

# Prove edits land in the workspace: write into the cwd System.cmd set via `cd:`.
echo "edited-by-stub" > stub_edit.txt

# Echo the prompt back so the adapter captures it as output.
echo "stub ran in: $(pwd)"
echo "prompt: ${prompt}"

exit "${STUB_EXIT:-0}"

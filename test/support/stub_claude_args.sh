#!/usr/bin/env bash
# Stub that emulates `claude -p` for Tier-2 boundary tests of
# Kazi.Harness.ClaudeAdapter's claw-code hygiene (T4.8). Like the other stubs it
# is NOT a lib/ stub (zero-stub policy applies to lib/ only) — it is a real
# external binary the adapter shells out to, exercising the genuine System.cmd
# boundary and the argv-assembly path end to end.
#
# Behaviour:
#   * Writes a marker file into the CURRENT WORKING DIRECTORY (proving the
#     adapter ran the harness in the target workspace, so edits land in place).
#   * Echoes EVERY argument it received, one per line, prefixed with `arg: ` so a
#     test can assert that the minimal tool/permission and per-dispatch budget
#     flags reached the harness in order.
#   * Exit code is controlled by STUB_EXIT (default 0).
set -euo pipefail

echo "edited-by-stub" > stub_edit.txt

for arg in "$@"; do
  echo "arg: ${arg}"
done

exit "${STUB_EXIT:-0}"

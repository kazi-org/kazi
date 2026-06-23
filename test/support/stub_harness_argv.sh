#!/usr/bin/env bash
# Stub harness for the T8.7 CLI wiring test. Like the other stubs it is a REAL
# external binary the adapter shells out to (zero-stub policy applies to lib/
# only), exercising the genuine System.cmd boundary.
#
# Behaviour:
#   * Records EVERY argument it received (one per line) to `harness_argv.txt` in
#     the CURRENT WORKING DIRECTORY, so the test can prove which harness profile
#     assembled the argv (e.g. opencode's `run ... --format json` vs claude's
#     `-p ... --output-format json`).
#   * Creates the marker file `fixed.txt` the goal's test_runner predicate checks,
#     so the dispatched run makes the goal converge.
#   * Emits a minimal JSON line on stdout (harmless to either profile's parser).
set -euo pipefail

printf '%s\n' "$@" > harness_argv.txt
echo ok > fixed.txt
echo '{"result":"done"}'

exit 0

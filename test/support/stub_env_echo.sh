#!/usr/bin/env bash
# Tiny stub for Tier-2 env-forwarding tests of Kazi.Harness.CliAdapter's
# optional `:env` opt (T8.8, ADR-0016). It is NOT a lib/ stub (the zero-stub
# policy applies to lib/ only) — it is a real external binary exercising the
# genuine subprocess path, so we can assert an env var reached `System.cmd`.
#
# Behaviour: echo the value of the env var named KAZI_TEST_ENV (empty if unset)
# on a single `env: <value>` line, so the test can recover it from stdout and
# confirm the adapter forwarded `:env`. Exits 0.
set -euo pipefail

echo "env: ${KAZI_TEST_ENV:-}"

exit 0

#!/usr/bin/env bash
#
# metric_doc_coverage.sh -- the doc-coverage RATCHET metric (T31.6, ADR-0036/0041).
#
# Prints ONE bare number to stdout: the percentage of shipped CLI commands that
# are documented in README.md (0..100, one decimal). It is the signal behind the
# doc-coverage `ratchet` predicate in priv/examples/doc_lifecycle.goal.toml, which
# asserts the percentage stays at or above its stored baseline (higher_better,
# allowed_regression 0 -- it may only improve).
#
# This is NOT a new check: it reuses the SAME authoritative command surface as
# predicate (a) (lib.sh:df_commands -> the `@commands` table in lib/kazi/cli.ex)
# and the SAME "documented" test (`grep -qF "kazi <cmd>" README.md`). Predicate
# (a) reports the boolean (all documented?); this metric reports the gradient
# (what fraction), so the standing goal can ratchet coverage up over time rather
# than only flipping pass/fail. No doc logic lives in kazi core -- this is a
# wrapper script alongside the T31.4 checkers, by design (ADR-0036 reject).
#
# Usage:
#   .github/scripts/doc_freshness/metric_doc_coverage.sh   # prints e.g. 85.7
# Exit: 0 (the metric always produces a number; an empty command table prints 0).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/doc_freshness/lib.sh
source "$HERE/lib.sh"

total=0
documented=0
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  total=$((total + 1))
  if grep -qF "kazi $cmd" "$README"; then
    documented=$((documented + 1))
  fi
done < <(df_commands)

if [ "$total" -eq 0 ]; then
  printf '0\n'
  exit 0
fi

# One-decimal percentage on stdout; the ratchet metric reads stdout as the number.
awk -v d="$documented" -v t="$total" 'BEGIN { printf "%.1f\n", (d / t) * 100 }'

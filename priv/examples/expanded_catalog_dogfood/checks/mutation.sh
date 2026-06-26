#!/usr/bin/env bash
# Mutation-testing grader for the :mutation provider (ADR-0043).
#
# Stands in for a real mutation tester: over a fixed set of 5 injected mutants,
# a mutant is "killed" by an assertion in tests/test_stats.py. score =
# killed / (killed + survived); the provider gates it on a threshold that is
# NEVER 100%. Surviving mutants are emitted as evidence.
set -euo pipefail
total=5
killed=$(grep -cE 'assert' tests/test_stats.py 2>/dev/null || true)
killed=${killed:-0}
if [ "$killed" -gt "$total" ]; then killed=$total; fi
survived=$((total - killed))
survivors="[]"
if [ "$survived" -gt 0 ]; then
  list=$(seq 1 "$survived" | sed 's/.*/"mutant-&"/' | paste -sd, -)
  survivors="[$list]"
fi
printf '{"killed": %s, "survived": %s, "survivors": %s}\n' "$killed" "$survived" "$survivors"

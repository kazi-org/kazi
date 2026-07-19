#!/usr/bin/env bash
# Patch-coverage grader for the :coverage provider (ADR-0043).
#
# Coverage % = (functions in src/stats.py that have a matching test_<name> in
# tests/test_stats.py) / (total functions) * 100. Emits JSON on stdout; the
# provider reads `$.percent`. A real run swaps this for a coverage tool's JSON.
set -euo pipefail
total=$(grep -cE '^def ' src/stats.py 2>/dev/null || true)
total=${total:-0}
tested=0
while IFS= read -r fn; do
  [ -z "$fn" ] && continue
  if grep -q "def test_${fn}" tests/test_stats.py 2>/dev/null; then
    tested=$((tested + 1))
  fi
done < <(grep -oE '^def [a-zA-Z_]+' src/stats.py 2>/dev/null | sed 's/^def //')
if [ "$total" -eq 0 ]; then pct=0; else pct=$((100 * tested / total)); fi
printf '{"percent": %s}\n' "$pct"

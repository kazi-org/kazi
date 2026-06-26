#!/usr/bin/env bash
# Static-analysis grader for the :static provider (ADR-0043), SARIF format.
#
# Flags every use of `eval(` in src/ as a SARIF result (the polyglot lingua
# franca of tsc/mypy/golangci-lint/Semgrep). The provider is gated on the PARSED
# findings, never the exit code, so we always exit 0 — the finding COUNT is the
# score (lower_better). A real run swaps this for a SARIF-emitting analyzer.
set -euo pipefail
results=""
while IFS=: read -r file line _rest; do
  [ -z "$file" ] && continue
  item=$(printf '{"ruleId":"no-unsafe-eval","level":"error","message":{"text":"unsafe eval() is forbidden"},"locations":[{"physicalLocation":{"artifactLocation":{"uri":"%s"},"region":{"startLine":%s}}}]}' "$file" "$line")
  if [ -z "$results" ]; then results="$item"; else results="$results,$item"; fi
done < <(grep -rn 'eval(' src/ 2>/dev/null || true)
printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"eval-lint"}},"results":[%s]}]}\n' "$results"
exit 0

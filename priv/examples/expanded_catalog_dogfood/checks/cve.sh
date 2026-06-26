#!/usr/bin/env bash
# Dependency-vulnerability grader for the :cve provider, manifest tier (ADR-0043).
#
# Stands in for a manifest scanner (trivy/grype/npm_audit tier-2): counts known-
# vulnerable pinned deps in requirements.txt. The provider ratchets `$.vulns`
# against baseline 0. requests==2.19.x carries known CVEs; a bump clears it.
set -euo pipefail
vulns=0
if grep -qE 'requests==2\.(19|20|21)\.' requirements.txt 2>/dev/null; then
  vulns=$((vulns + 1))
fi
printf '{"vulns": %s}\n' "$vulns"

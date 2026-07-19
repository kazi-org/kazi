#!/usr/bin/env bash
#
# Predicate (g) -- every `spec:` behavior-spec pointer in the LIVE WBS
# (docs/plan.md + docs/plans/*.md) resolves to an existing file (T40.5,
# ADR-0050 / ADR-0036). Mirrors predicate (c) (every referenced ADR exists).
#
# A plan task may point at its behavior spec via `spec: docs/specs/<slug>.feature`
# (ADR-0050, T40.3). A pointer to a file that does not exist is a FAIL, reported
# with the file:line that cited it, so the offending task is locatable. Scans
# ONLY the live WBS (the master + the split epic files, non-recursive so
# docs/plans/archive/ is out of scope) -- the archived tier legitimately holds
# moved specs, and the doc bodies are not the WBS.
#
# Usage:
#   .github/scripts/doc_freshness/check_g_spec_refs_exist.sh
# Exit: 0 = pass, 1 = fail.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/doc_freshness/lib.sh
source "$HERE/lib.sh"

rel() { printf '%s' "${1#"$DF_ROOT/"}"; }

# `spec: <path>` where <path> ends in .feature or .md (the pointer form parse_plan
# recognises, T40.3). The path class excludes `<>` so a literal placeholder like
# `spec: docs/specs/<slug>.feature` in epic PROSE is not mistaken for a live
# pointer (real paths never contain angle brackets).
spec_re='spec:[[:space:]]+[^[:space:]<>]+\.(feature|md)'

# The live WBS: the master plus every split epic file (non-recursive glob, so
# docs/plans/archive/ is excluded -- same scope as the plan-trimmed check).
wbs_files=("$DF_ROOT/docs/plan.md")
for f in "$DF_ROOT"/docs/plans/*.md; do
  [ -e "$f" ] && wbs_files+=("$f")
done

offenders=0
while IFS= read -r hit; do
  file="${hit%%:*}"
  rest="${hit#*:}"
  lineno="${rest%%:*}"
  text="${rest#*:}"

  # Strip the `spec:` label off the matched field, leaving the path.
  path="$(printf '%s' "$text" | grep -oE "$spec_re" | sed -E 's/^spec:[[:space:]]+//' || true)"
  [ -n "$path" ] || continue

  if [ ! -e "$DF_ROOT/$path" ]; then
    df_fail "(g) spec: points at ${path} but no such file -> $(rel "$file"):${lineno}"
    offenders=$((offenders + 1))
  fi
done < <(grep -HnE "$spec_re" "${wbs_files[@]}" 2>/dev/null || true)

if [ "$offenders" -eq 0 ]; then
  df_pass "(g) every spec: pointer in the live WBS resolves to an existing file"
  exit 0
fi
exit 1

#!/usr/bin/env bash
#
# Predicate (c) -- every ADR referenced by a doc actually EXISTS as a file in
# docs/adr/ (T31.4, ADR-0036).
#
# Scans README.md + all of docs/ (including docs/adr/** -- a cross-reference
# between ADRs must also resolve) for ADR references in any of these forms:
#
#   ADR-0027        ADR 0027        docs/adr/0027-...
#
# For each distinct 4-digit number N, require docs/adr/N-*.md to exist. A
# reference with no matching file is a FAIL, reported with the first file:line
# that cited it (so the offender is locatable).
#
# Usage:
#   .github/scripts/doc_freshness/check_c_adr_refs_exist.sh
# Exit: 0 = pass, 1 = fail.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/doc_freshness/lib.sh
source "$HERE/lib.sh"

rel() { printf '%s' "${1#"$DF_ROOT/"}"; }

# Reference regex (extended): ADR-NNNN | ADR NNNN | docs/adr/NNNN
adr_re='(ADR[- ][0-9]{4}|docs/adr/[0-9]{4})'

offenders=0
seen_bad=""

# Walk README + every markdown file under docs/. grep -rn gives file:line:text.
while IFS= read -r hit; do
  file="${hit%%:*}"
  rest="${hit#*:}"
  lineno="${rest%%:*}"
  text="${rest#*:}"

  # Pull every ADR number out of this line (a line may cite several). We grep
  # the matched references, then strip everything but the 4-digit number on each
  # match -- reading line by line so an `ADR NNNN` form (internal space) is not
  # split into two bogus tokens.
  while IFS= read -r num; do
    [ -n "$num" ] || continue
    # Skip if we already reported this missing number.
    case " $seen_bad " in *" $num "*) continue ;; esac
    # Does a docs/adr/<num>-*.md exist?
    if ! ls "$DF_ROOT/docs/adr/${num}-"*.md >/dev/null 2>&1; then
      df_fail "(c) reference to ADR-${num} but no docs/adr/${num}-*.md -> $(rel "$file"):${lineno}"
      seen_bad="$seen_bad $num"
      offenders=$((offenders + 1))
    fi
  done < <(printf '%s\n' "$text" | grep -oE "$adr_re" | grep -oE '[0-9]{4}')
  # This predicate's own doc cites ADR-9999 as a dangling EXAMPLE; exclude it so
  # the example does not self-trip (mirrors the leak guard excluding its own doc).
done < <(grep -rnE "$adr_re" "$README" "$DF_ROOT/docs" 2>/dev/null \
  | grep -v '/docs/doc-freshness.md:' || true)

if [ "$offenders" -eq 0 ]; then
  df_pass "(c) every ADR referenced by a doc exists in docs/adr/"
  exit 0
fi
exit 1

#!/usr/bin/env bash
#
# Predicate (d) -- no `[x]` (done) task in the LIVE plan (docs/plan.md) is older
# than the last release tag (T31.4, ADR-0036).
#
# Rationale: once completed work has shipped in a release, ADR-0036's Layer-1
# trim (T31.2) is supposed to archive it out of the live plan. A `[x]` task whose
# `Done: YYYY-MM-DD` date is on or before the last release tag's date is stale
# residue that should have been trimmed. This predicate REPORTS such offenders;
# it does not trim them (that is T31.2).
#
# NOTE: this predicate will legitimately FAIL today, because the trim tool
# (T31.2) has not run yet. That is EXPECTED -- T31.4 is the DEFINITION layer; the
# check just enumerates the offenders a future trim will clear.
#
# Two offender classes:
#   1. `[x]` task with `Done: <date>` where date <= last-release-tag date.
#   2. `[x]` task with NO `Done:` date at all (cannot prove it post-dates the
#      release; also a hygiene gap). Reported distinctly.
#
# Each offender is reported with docs/plan.md:<line> and the task id.
#
# Env:
#   RELEASE_REF  the tag/ref whose commit date is the cutoff (default: the most
#                recent SEMANTIC version tag matching `v*`, by creation date --
#                NOT the e2e CI tags like `release-kazi-...`).
#
# Usage:
#   .github/scripts/doc_freshness/check_d_plan_trimmed.sh
# Exit: 0 = pass, 1 = fail.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/doc_freshness/lib.sh
source "$HERE/lib.sh"

PLAN="$DF_ROOT/docs/plan.md"

# Resolve the last release tag and its date (YYYY-MM-DD, committer date).
# Most recent semantic version tag (v1.2.3 ...), newest first by creation date.
RELEASE_REF="${RELEASE_REF:-$(git -C "$DF_ROOT" tag --list 'v*' --sort=-creatordate 2>/dev/null | head -1)}"
if [ -z "$RELEASE_REF" ]; then
  df_fail "(d) no release tag found (git describe --tags) -- cannot evaluate plan trim"
  exit 1
fi
RELEASE_DATE="$(git -C "$DF_ROOT" log -1 --format='%cs' "$RELEASE_REF" 2>/dev/null || true)"
if [ -z "$RELEASE_DATE" ]; then
  df_fail "(d) could not resolve a commit date for release ref '$RELEASE_REF'"
  exit 1
fi

offenders=0
undated=0

# Walk every `- [x]` task line in the LIVE plan with its file + line number. The
# live plan is the master `docs/plan.md` PLUS, in the split layout (T31.1), each
# `docs/plans/<epic>.md` epic file (where the task lines move). `grep -H` forces a
# file prefix; the `docs/plans/*.md` glob is empty on a monolithic plan, so this is
# backward-compatible (it then walks `docs/plan.md` exactly as before).
while IFS=: read -r file lineno text; do
  # Extract the task id (e.g. T9.5) for a readable report.
  tid="$(df_extract "$text" 'T[0-9]+\.[0-9]+[a-z]?')"
  [ -n "$tid" ] || tid='(no-id)'
  rel="${file#"$DF_ROOT/"}"

  done_date="$(df_extract "$text" 'Done: [0-9]{4}-[0-9]{2}-[0-9]{2}')"
  done_date="${done_date#Done: }"

  if [ -z "$done_date" ]; then
    df_fail "(d) [x] ${tid} has no Done: date -> ${rel}:${lineno} (cannot prove it post-dates ${RELEASE_REF})"
    undated=$((undated + 1))
    offenders=$((offenders + 1))
    continue
  fi

  # String comparison is valid for ISO-8601 YYYY-MM-DD dates.
  if [[ "$done_date" < "$RELEASE_DATE" || "$done_date" == "$RELEASE_DATE" ]]; then
    df_fail "(d) [x] ${tid} done ${done_date} <= release ${RELEASE_REF} (${RELEASE_DATE}); should be trimmed -> ${rel}:${lineno}"
    offenders=$((offenders + 1))
  fi
done < <(grep -HnE '^- \[x\]' "$PLAN" "$DF_ROOT"/docs/plans/*.md 2>/dev/null || true)

if [ "$offenders" -eq 0 ]; then
  df_pass "(d) no done+released task lingers in the live plan (cutoff ${RELEASE_REF} ${RELEASE_DATE})"
  exit 0
fi

printf '      ----\n'
printf '      (d) %d offender(s): %d dated <= %s, %d undated. EXPECTED to fail until T31.2 trims.\n' \
  "$offenders" "$((offenders - undated))" "$RELEASE_DATE" "$undated"
exit 1

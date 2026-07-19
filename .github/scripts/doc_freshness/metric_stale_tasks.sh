#!/usr/bin/env bash
#
# metric_stale_tasks.sh -- the stale-task COUNT ratchet metric (T31.6, ADR-0036/0041).
#
# Prints ONE bare number to stdout: how many `- [x]` (done) tasks in the LIVE plan
# are stale residue the ADR-0036 Layer-1 trim (T31.2) should have archived -- a
# `Done:` date on or before the last release tag, OR no `Done:` date at all. It is
# the signal behind the "stale tasks ratchet to 0" predicate in
# priv/examples/doc_lifecycle.goal.toml (a `lower_better` ratchet with baseline 0,
# so it passes only when the count reaches 0 and reports the gradient meanwhile).
#
# This is NOT a new check: it counts EXACTLY the offenders predicate (d)
# (check_d_plan_trimmed.sh) enumerates, using the same release cutoff and the same
# live-plan walk (master docs/plan.md PLUS each docs/plans/*.md epic file, T31.1).
# Predicate (d) reports the boolean (any stale?); this metric reports the count, so
# the standing goal can ratchet it down to zero. No doc logic in kazi core.
#
# Env:
#   RELEASE_REF  the tag/ref whose commit date is the cutoff (default: the newest
#                semantic `v*` tag by creation date) -- identical to check_d.
#
# Usage:
#   .github/scripts/doc_freshness/metric_stale_tasks.sh   # prints e.g. 12
# Exit: 0 (always emits a count; a resolvable-cutoff failure prints nothing and
#        exits 1 so the ratchet records an :error, never a false 0).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/doc_freshness/lib.sh
source "$HERE/lib.sh"

PLAN="$DF_ROOT/docs/plan.md"

RELEASE_REF="${RELEASE_REF:-$(git -C "$DF_ROOT" tag --list 'v*' --sort=-creatordate 2>/dev/null | head -1)}"
if [ -z "$RELEASE_REF" ]; then
  # No release to compare against: emit nothing and fail so the ratchet records an
  # :error (a broken metric), never a silent 0 that would falsely read as "clean".
  echo "metric_stale_tasks: no release tag found (git tag --list 'v*')" >&2
  exit 1
fi
RELEASE_DATE="$(git -C "$DF_ROOT" log -1 --format='%cs' "$RELEASE_REF" 2>/dev/null || true)"
if [ -z "$RELEASE_DATE" ]; then
  echo "metric_stale_tasks: could not resolve a commit date for '$RELEASE_REF'" >&2
  exit 1
fi

offenders=0
while IFS=: read -r _file _lineno text; do
  done_date="$(df_extract "$text" 'Done: [0-9]{4}-[0-9]{2}-[0-9]{2}')"
  done_date="${done_date#Done: }"
  if [ -z "$done_date" ]; then
    # Undated [x] task: cannot prove it post-dates the release -> stale residue.
    offenders=$((offenders + 1))
    continue
  fi
  # ISO-8601 string comparison: done on/before the release cutoff is stale.
  if [[ "$done_date" < "$RELEASE_DATE" || "$done_date" == "$RELEASE_DATE" ]]; then
    offenders=$((offenders + 1))
  fi
done < <(grep -hnE '^- \[x\]' "$PLAN" "$DF_ROOT"/docs/plans/*.md 2>/dev/null || true)

printf '%s\n' "$offenders"

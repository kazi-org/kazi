#!/usr/bin/env bash
#
# docs_with_code_guard.sh (T29.1, ADR-0034 gate 1)
#
# Flags a change that touches a user-facing / behavioral surface in lib/
# (a command or flag in lib/kazi/cli.ex, a predicate provider, a public API)
# WITHOUT a corresponding docs change (docs/, README.md, AGENTS.md, or the
# kazi help surface). An escape hatch lets a justified change pass: include the
# literal marker [no-docs] in the PR title or in any commit message on the
# branch.
#
# Phase 1 (current): STRICT-BUT-WARN. A violation is REPORTED but the script
# still exits 0, so the CI step is non-blocking. To ratchet to blocking, set
#   BLOCKING=1
# (env var) or flip the DEFAULT_BLOCKING constant below. When blocking, a
# violation exits 1.
#
# Local usage:
#   .github/scripts/docs_with_code_guard.sh            # diff vs origin/main
#   BASE_REF=origin/develop .github/scripts/docs_with_code_guard.sh
#   BLOCKING=1 .github/scripts/docs_with_code_guard.sh # behave as ratcheted gate
#
# The base ref is read from BASE_REF (default origin/main) so a contributor can
# run the guard before pushing, and CI can point it at the PR base branch.

set -euo pipefail

# --- configuration ---------------------------------------------------------

# Phase toggle. Flip DEFAULT_BLOCKING to 1 (or export BLOCKING=1) to ratchet
# this guard from warn-only to blocking once the team is ready.
DEFAULT_BLOCKING=0
BLOCKING="${BLOCKING:-$DEFAULT_BLOCKING}"

BASE_REF="${BASE_REF:-origin/main}"

# Surface-defining code paths: a change here is "behavioral / user-facing".
# Kept deliberately narrow so a pure internal refactor elsewhere in lib/ does
# not trip the guard.
SURFACE_PATTERNS=(
  '^lib/kazi/cli\.ex$'
  '^lib/kazi/cli/'
  '^lib/kazi/providers/'
  '^lib/kazi/predicate_provider\.ex$'
  '^lib/kazi/harness_adapter\.ex$'
  '^lib/kazi/mcp/'
)

# Paths that count as a documentation update.
DOC_PATTERNS=(
  '^docs/'
  '^README\.md$'
  '^AGENTS\.md$'
)

# --- helpers ---------------------------------------------------------------

log()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# Resolve a usable base SHA. Fail gracefully if the ref is not present
# (e.g. a shallow checkout that did not fetch the base).
resolve_base() {
  if git rev-parse --verify --quiet "${BASE_REF}" >/dev/null; then
    git merge-base "${BASE_REF}" HEAD 2>/dev/null || git rev-parse "${BASE_REF}"
    return 0
  fi
  return 1
}

matches_any() {
  local path="$1"; shift
  local pat
  for pat in "$@"; do
    if printf '%s' "${path}" | grep -Eq "${pat}"; then
      return 0
    fi
  done
  return 1
}

# --- main ------------------------------------------------------------------

log "== docs-with-code guard (T29.1) =="

if ! base_sha="$(resolve_base)"; then
  log "WARN: base ref '${BASE_REF}' not found; cannot compute a diff. Skipping."
  log "      (In CI, check out with fetch-depth: 0 and fetch the base branch.)"
  exit 0
fi

changed_files="$(git diff --name-only "${base_sha}"...HEAD)"

if [ -z "${changed_files}" ]; then
  log "No changed files vs ${BASE_REF}. Nothing to check."
  exit 0
fi

surface_hits=""
doc_hit=0

while IFS= read -r f; do
  [ -z "${f}" ] && continue
  if matches_any "${f}" "${SURFACE_PATTERNS[@]}"; then
    surface_hits="${surface_hits}${f}"$'\n'
  fi
  if matches_any "${f}" "${DOC_PATTERNS[@]}"; then
    doc_hit=1
  fi
done <<EOF
${changed_files}
EOF

if [ -z "${surface_hits}" ]; then
  log "No user-facing surface changed. Guard not applicable. PASS."
  exit 0
fi

log "User-facing surface changed in this diff:"
printf '%s' "${surface_hits}" | while IFS= read -r f; do
  [ -n "${f}" ] && note "${f}"
done

if [ "${doc_hit}" -eq 1 ]; then
  log "A docs change is present in the same diff. PASS."
  exit 0
fi

# No docs. Look for a justified [no-docs] escape hatch in the PR title
# (PR_TITLE env, set by CI) or any commit message on the branch.
pr_title="${PR_TITLE:-}"
commit_msgs="$(git log --format='%B' "${base_sha}"..HEAD 2>/dev/null || true)"

if printf '%s\n%s' "${pr_title}" "${commit_msgs}" | grep -Fq '[no-docs]'; then
  log "Surface changed without docs, but a justified [no-docs] marker is present. PASS."
  exit 0
fi

# Violation.
log ""
log "VIOLATION: a user-facing surface changed but no docs (docs/, README.md,"
log "           AGENTS.md) were updated, and no [no-docs] justification was found."
log ""
log "Fix one of:"
log "  - update the matching docs in the same change, or"
log "  - add a justified '[no-docs]' marker to the PR title or a commit message"
log "    (use this ONLY for a trivial internal refactor with no surface change)."

if [ "${BLOCKING}" = "1" ]; then
  log ""
  log "Guard is in BLOCKING mode -> failing."
  exit 1
fi

log ""
log "Guard is in phase-1 WARN mode -> reporting only, exiting 0."
log "(Set BLOCKING=1 to ratchet this to a blocking check.)"
exit 0

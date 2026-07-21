#!/usr/bin/env bash
#
# no_attribution_guard.sh (ADR-0034)
#
# FAILS when a commit message or an added line carries an agent attribution or
# self-promotion trailer:
#   - Co-Authored-By: <any AI assistant>
#   - "Generated with <assistant>" / "Created by <assistant>"
#
# WHY THIS IS A GATE AND NOT JUST A DOC RULE
#
# An agent dispatched by `kazi apply` on a fresh machine reads this repo's
# CLAUDE.md/AGENTS.md but NOT the operator's own `~/.claude` config, so a rule
# that lives only in an operator's global config never reaches it. On
# 2026-07-21 a dispatched agent added `Co-Authored-By:` trailers to all five
# commits of an otherwise-good change; they were caught by hand at review, not
# by any gate. This is that gate.
#
# SCOPE: commit messages in BASE_REF..HEAD, plus lines ADDED by that diff.
# This guard is BLOCKING: a real hit exits 1.
#
# An inline `attribution-guard:allow` marker on the offending line exempts it
# (for docs that must quote the forbidden string -- like this file's own tests).
#
# Local usage:
#   .github/scripts/no_attribution_guard.sh
#   BASE_REF=origin/develop .github/scripts/no_attribution_guard.sh
#
# Test mode (no git): pipe candidate lines on stdin --
#   printf 'Co-Authored-By: Claude <x@y>\n' | ATTRIB_STDIN=1 .github/scripts/no_attribution_guard.sh  # attribution-guard:allow

set -euo pipefail

BASE_REF="${BASE_REF:-origin/main}"
ATTRIB_STDIN="${ATTRIB_STDIN:-0}"

# Case-insensitive. Deliberately narrow: a "Co-Authored-By" naming a HUMAN
# collaborator is legitimate and must keep passing, so the assistant-name
# alternation is what makes this fire.
ASSISTANTS='claude|chatgpt|gpt-4|gpt-5|copilot|codex|cursor|gemini|anthropic\.com'
PATTERNS=(
  "co-authored-by:.*(${ASSISTANTS})"
  "(generated|created|written|authored) (with|by) .*(${ASSISTANTS})"
  "🤖 generated" # attribution-guard:allow
)

ALLOW_MARKER='attribution-guard:allow'

scan() {
  # stdin: candidate lines. Emits offending lines, returns 1 if any.
  local found=0 line pat
  while IFS= read -r line; do
    case "$line" in *"$ALLOW_MARKER"*) continue ;; esac
    for pat in "${PATTERNS[@]}"; do
      if printf '%s' "$line" | grep -qiE "$pat"; then
        printf '  %s\n' "$line"
        found=1
        break
      fi
    done
  done
  return $found
}

if [ "$ATTRIB_STDIN" = "1" ]; then
  if scan; then
    echo "attribution guard OK (stdin)."
    exit 0
  fi
  echo "attribution guard FAILED (ADR-0034): attribution trailer found."
  exit 1
fi

hits=""

# 1) Commit messages in range.
if git rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
  msgs="$(git log --format='%B' "${BASE_REF}..HEAD" 2>/dev/null || true)"
  if [ -n "$msgs" ]; then
    if ! commit_hits="$(printf '%s\n' "$msgs" | scan)"; then
      hits="${hits}${commit_hits}\n"
    fi
  fi
fi

# 2) Lines ADDED by the diff (an attribution baked into a file, not a message).
added="$(git diff "${BASE_REF}...HEAD" 2>/dev/null | grep '^+' | grep -v '^+++' | sed 's/^+//' || true)"
if [ -n "$added" ]; then
  if ! diff_hits="$(printf '%s\n' "$added" | scan)"; then
    hits="${hits}${diff_hits}\n"
  fi
fi

if [ -n "${hits//[[:space:]\\n]/}" ]; then
  echo "attribution guard FAILED (ADR-0034): commits and files in this repo carry no agent attribution."
  printf '%b' "$hits"
  echo
  echo "Fix: remove the trailer. To strip it from existing commits in range:"
  echo "  git filter-branch -f --msg-filter 'grep -v \"^Co-Authored-By:\" || true' ${BASE_REF}..HEAD"
  exit 1
fi

echo "attribution guard OK (no attribution trailers in commits or added lines)."

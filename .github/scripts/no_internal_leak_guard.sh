#!/usr/bin/env bash
#
# no_internal_leak_guard.sh (T29.2, ADR-0034 gate 2)
#
# Scans for internal-only markers and FAILS on a real hit:
#   - private IPs:   192.168.x.x, 10.x.x.x, 172.16-31.x.x
#   - absolute home paths: /Users/<name>/..., /home/<name>/...
#   - internal infra / tool / codenames (extend INTERNAL_NAMES below)
#
# An ALLOW-LIST keeps legitimate cases passing:
#   - RFC-5737 example IPs: 192.0.2.x, 198.51.100.x, 203.0.113.x
#   - loopback / unspecified: 127.0.0.1, 0.0.0.0, localhost
#   - placeholder home paths: /Users/<name>, /home/<user> (literal placeholders)
#   - any line carrying the inline marker  leak-guard:allow
#
# SCOPE: by default the guard scans only the DIFF of the PR (added lines) vs a
# base ref, so the ~48 pre-existing leaks (scrubbed separately by T29.3) do not
# red every PR. Once T29.3 lands, flip SCAN_TREE=1 to also scan the full working
# tree and catch leaks that already sit in committed files.
#
# This guard is BLOCKING: a real hit exits 1.
#
# Local usage:
#   .github/scripts/no_internal_leak_guard.sh             # scan diff vs origin/main
#   BASE_REF=origin/develop .github/scripts/no_internal_leak_guard.sh
#   SCAN_TREE=1 .github/scripts/no_internal_leak_guard.sh # also scan whole tree
#
# Test mode (no git): pipe candidate lines on stdin --
#   printf '+ host 192.168.5.5\n' | LEAK_STDIN=1 .github/scripts/no_internal_leak_guard.sh

set -euo pipefail

# --- configuration ---------------------------------------------------------

BASE_REF="${BASE_REF:-origin/main}"
SCAN_TREE="${SCAN_TREE:-0}"     # 1 => also scan the full working tree (post-T29.3)
LEAK_STDIN="${LEAK_STDIN:-0}"   # 1 => read candidate lines from stdin (test mode)

# Internal infra / tool / codenames. Extend as needed. Matched case-insensitively
# as whole-ish tokens. Keep these GENERIC placeholders in this public file -- do
# NOT add the real internal names here, or this guard would itself leak them.
# (Real names live only in the operator's private config, never in the repo.)
INTERNAL_NAMES=(
  # 'examplecorp-internal'   # template: add internal codenames in a private fork
)

# Files/paths the scan should ignore entirely (the guard + its own docs, which
# legitimately contain example markers).
EXCLUDE_PATHS=(
  '^\.github/scripts/no_internal_leak_guard\.sh$'
  '^\.github/scripts/docs_with_code_guard\.sh$'
  '^docs/oss-gates\.md$'
  '^\.github/workflows/oss-gates\.yml$'
)

# Inline allow marker: any line containing this token is exempt (for the rare
# legitimate case, e.g. a documented example hostname in a fixture).
ALLOW_MARKER='leak-guard:allow'

# --- patterns --------------------------------------------------------------

# Private IPv4 ranges (RFC-1918), as a single ERE.
#   192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12
PRIVATE_IP_RE='(^|[^0-9.])(192\.168\.[0-9]{1,3}\.[0-9]{1,3}|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'

# Absolute home paths: /Users/<name>/ or /home/<name>/ where <name> is a real
# user token (letters/digits), NOT a literal placeholder like <name> or <user>.
HOME_PATH_RE='(/Users/|/home/)[A-Za-z0-9_][A-Za-z0-9_.-]*'

# Allow-listed tokens that must NOT count as a leak even though they look IP-ish.
# RFC-5737 example ranges + loopback/unspecified.
ALLOW_IP_RE='(192\.0\.2\.[0-9]{1,3}|198\.51\.100\.[0-9]{1,3}|203\.0\.113\.[0-9]{1,3}|127\.0\.0\.1|0\.0\.0\.0)'

# Placeholder home paths that are documentation, not a real leak. Only an
# explicit angle-bracket placeholder (<name>, <user>, ...) or an all-caps
# template token (NAME, USER, USERNAME) counts as a placeholder. A bare lower
# case username like /Users/someone IS a real leak and must NOT be allow-listed.
ALLOW_HOME_RE='/(Users|home)/(<[A-Za-z0-9_-]+>|NAME|USER|USERNAME|YOU)([/ ]|$)'

# --- helpers ---------------------------------------------------------------

log()  { printf '%s\n' "$*"; }

excluded_path() {
  local path="$1" pat
  for pat in "${EXCLUDE_PATHS[@]}"; do
    if printf '%s' "${path}" | grep -Eq "${pat}"; then
      return 0
    fi
  done
  return 1
}

resolve_base() {
  if git rev-parse --verify --quiet "${BASE_REF}" >/dev/null; then
    git merge-base "${BASE_REF}" HEAD 2>/dev/null || git rev-parse "${BASE_REF}"
    return 0
  fi
  return 1
}

# Decide whether one candidate line is a leak. Strips a leading diff '+' marker
# and the "path:lineno:" prefix that grep -n adds, before allow-list checks.
# Echoes nothing; returns 0 if it IS a leak, 1 otherwise.
is_leak_line() {
  local line="$1"

  # Inline allow marker exempts the whole line.
  if printf '%s' "${line}" | grep -Fq "${ALLOW_MARKER}"; then
    return 1
  fi

  # Strip an allow-listed IP / home placeholder out of the line first, so a line
  # that ONLY contains allow-listed tokens cannot trip the private patterns.
  local stripped
  stripped="$(printf '%s' "${line}" \
    | sed -E "s#${ALLOW_IP_RE}#__ALLOWED_IP__#g" \
    | sed -E "s#${ALLOW_HOME_RE}#__ALLOWED_HOME__#g")"

  if printf '%s' "${stripped}" | grep -Eq "${PRIVATE_IP_RE}"; then
    return 0
  fi
  if printf '%s' "${stripped}" | grep -Eq "${HOME_PATH_RE}"; then
    return 0
  fi

  # Internal names (if any configured).
  if [ "${#INTERNAL_NAMES[@]}" -gt 0 ]; then
    local name
    for name in "${INTERNAL_NAMES[@]}"; do
      [ -z "${name}" ] && continue
      if printf '%s' "${stripped}" | grep -Eiq "(^|[^A-Za-z0-9])${name}([^A-Za-z0-9]|$)"; then
        return 0
      fi
    done
  fi

  return 1
}

# --- gather candidate lines ------------------------------------------------

# Each candidate is emitted as "context\tpayload" where context is a human label
# (path:lineno or "stdin") and payload is the text to test.
gather() {
  if [ "${LEAK_STDIN}" = "1" ]; then
    local n=0
    while IFS= read -r raw; do
      n=$((n + 1))
      printf 'stdin:%s\t%s\n' "${n}" "${raw}"
    done
    return 0
  fi

  if [ "${SCAN_TREE}" = "1" ]; then
    # Full-tree scan (post-T29.3). Pre-filter the whole tree with ONE `git grep`
    # for the broad leak patterns (fast: only candidate lines come back), then
    # is_leak_line() in the main loop confirms each against the allow-list. This
    # avoids spawning the per-line subprocess matrix for every line in the repo
    # (the naive line-by-line scan took minutes and timed out). Case-insensitive
    # pre-filter -- it only widens candidates; is_leak_line is the authoritative,
    # case-correct confirmer. Emit "path:lineno\tcontent" (TAB) for the main loop.
    local prefilter="${PRIVATE_IP_RE}|${HOME_PATH_RE}"
    if [ "${#INTERNAL_NAMES[@]}" -gt 0 ]; then
      local name
      for name in "${INTERNAL_NAMES[@]}"; do
        [ -z "${name}" ] && continue
        prefilter="${prefilter}|${name}"
      done
    fi
    git grep -nIiE "${prefilter}" 2>/dev/null | while IFS= read -r m; do
      # git grep -n yields "path:lineno:content".
      local path rest
      path="${m%%:*}"
      rest="${m#*:}"
      excluded_path "${path}" && continue
      printf '%s:%s\t%s\n' "${path}" "${rest%%:*}" "${rest#*:}"
    done || true
    return 0
  fi

  # Default: diff-only scan of ADDED lines vs the base.
  local base_sha
  if ! base_sha="$(resolve_base)"; then
    log "WARN: base ref '${BASE_REF}' not found; cannot compute a diff." >&2
    log "      (In CI, check out with fetch-depth: 0 and fetch the base branch.)" >&2
    return 0
  fi

  # Walk the unified diff; track the current file from +++ headers; emit only
  # added lines (leading '+', not the +++ header) from non-excluded files.
  local cur=""
  git diff --unified=0 "${base_sha}"...HEAD | while IFS= read -r dl; do
    case "${dl}" in
      '+++ b/'*)
        cur="${dl#+++ b/}"
        ;;
      '+++ '*)
        cur=""
        ;;
      '+'*)
        [ -z "${cur}" ] && continue
        excluded_path "${cur}" && continue
        # strip the leading '+'
        printf '%s\t%s\n' "${cur}" "${dl#+}"
        ;;
    esac
  done
}

# --- main ------------------------------------------------------------------

log "== no-internal-leak guard (T29.2) =="
if [ "${SCAN_TREE}" = "1" ]; then
  log "mode: FULL TREE scan"
elif [ "${LEAK_STDIN}" = "1" ]; then
  log "mode: stdin (test)"
else
  log "mode: DIFF scan vs ${BASE_REF} (added lines only)"
fi

hits=0
while IFS=$'\t' read -r ctx payload; do
  [ -z "${ctx:-}" ] && continue
  if is_leak_line "${payload}"; then
    if [ "${hits}" -eq 0 ]; then
      log ""
      log "INTERNAL LEAK(S) DETECTED:"
    fi
    hits=$((hits + 1))
    log "  ${ctx}: ${payload}"
  fi
done < <(gather)

if [ "${hits}" -gt 0 ]; then
  log ""
  log "FAIL: ${hits} internal-marker hit(s). Genericize or remove them."
  log "  - private IPs (192.168.*/10.*/172.16-31.*): use RFC-5737 examples"
  log "    (192.0.2.x / 198.51.100.x / 203.0.113.x) or localhost/127.0.0.1."
  log "  - absolute home paths (/Users/<name>, /home/<name>): use a placeholder."
  log "  - internal infra/tool/codenames: genericize ('a local model')."
  log "  - if a hit is a legitimate documented example, append '${ALLOW_MARKER}'"
  log "    to that line."
  exit 1
fi

log "No internal-marker leaks found. PASS."
exit 0

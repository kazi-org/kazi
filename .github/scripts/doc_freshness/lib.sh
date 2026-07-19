#!/usr/bin/env bash
#
# lib.sh -- shared helpers for the doc-freshness predicate set (T31.4, ADR-0036).
#
# Sourced by each predicate script and by the runner doc_freshness.sh. Keeps the
# command-list extraction in ONE place so predicates (a) and (b) agree on the
# authoritative command surface.
#
# Command source (documented choice):
#   We parse the `@commands` table in lib/kazi/cli.ex by grep/awk, NOT
#   `kazi help --json`. The table is the source of truth from which `help --json`
#   is GENERATED (see the moduledoc in lib/kazi/cli.ex), so parsing it needs no
#   built binary and no Elixir runtime -- the checks run in a bare CI shell. If a
#   built `kazi` binary is on PATH a maintainer can cross-check with
#   `kazi help --json | jq -r '.commands[].name'`; the two MUST match (the
#   help-json ExUnit test already pins that). Here we stay runtime-free.

set -euo pipefail

# Repo root: three levels up from .github/scripts/doc_freshness/.
DF_ROOT="${DF_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
export DF_ROOT

CLI_FILE="$DF_ROOT/lib/kazi/cli.ex"
README="$DF_ROOT/README.md"
export CLI_FILE README

# df_commands -- print the shipped CLI command names, one per line, sorted.
#
# Extracts every command `name: "<cmd>"` inside the `@commands [...]` block of
# lib/kazi/cli.ex. A COMMAND entry is a `name:` line on its own, immediately
# followed by a `summary:` line; arg entries (`args: [%{name: "goal-file"...}]`)
# put `name:` inline and are NOT followed by `summary:`, so the look-ahead
# excludes them. We also bound the scan to the @commands block so an unrelated
# `name:` elsewhere in the file cannot leak in.
df_commands() {
  awk '
    /^  @commands \[/ { inblk = 1; next }
    inblk && /^  \]/  { inblk = 0 }
    # remember a candidate command name on its own line; confirm on next line.
    inblk && /^      name: "[a-z][a-z-]*",?$/ {
      s = $0
      sub(/^.*name: "/, "", s)
      sub(/".*$/, "", s)
      pending = s
      next
    }
    inblk && pending != "" {
      if ($0 ~ /^      summary:/) print pending
      pending = ""
    }
  ' "$CLI_FILE" | sort -u
}

# df_pass / df_fail -- uniform PASS/FAIL line. The caller supplies a message
# that already carries any offending location.
df_pass() { printf 'PASS  %s\n' "$1"; }
df_fail() { printf 'FAIL  %s\n' "$1"; }

# df_extract <text> <ere> -- print the FIRST regex match in <text>, or nothing.
#
# A no-match returns empty WITHOUT a nonzero exit, so it is safe to use in a
# `var="$(df_extract ...)"` assignment under `set -euo pipefail` (a bare
# `grep | head` there can abort the script on no-match or SIGPIPE).
df_extract() {
  printf '%s\n' "$1" | grep -oE "$2" 2>/dev/null | head -n 1 || true
}

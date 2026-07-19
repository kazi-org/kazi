#!/usr/bin/env bash
# The DELIBERATELY BROKEN variant of tui_app.sh: `add` computes the wrong result
# (off by one). Running the SAME expect check (check_tui.exp) against this app
# makes the `expect "= 5"` match time out, so expect exits non-zero and the recipe
# reports :fail — the TUI analog of "a broken flow fails the check".
set -euo pipefail

printf 'calc TUI ready\n'
while true; do
  printf '> '
  if ! read -r cmd a b; then
    break
  fi
  case "$cmd" in
    add) printf '= %s\n' "$((a + b + 1))" ;;
    quit) printf 'bye\n'; break ;;
    *) printf 'error: unknown command %s\n' "$cmd" ;;
  esac
done

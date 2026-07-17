#!/usr/bin/env bash
# A minimal but REAL interactive terminal UI: a prompt loop that reads commands
# from the tty and prints results, exactly the kind of surface the expect-driven
# recipe asserts against. Not a stub — it does real work (integer add) and only
# the driving/assertion is what the recipe exercises.
set -euo pipefail

printf 'calc TUI ready\n'
while true; do
  printf '> '
  if ! read -r cmd a b; then
    break
  fi
  case "$cmd" in
    add) printf '= %s\n' "$((a + b))" ;;
    quit) printf 'bye\n'; break ;;
    *) printf 'error: unknown command %s\n' "$cmd" ;;
  esac
done

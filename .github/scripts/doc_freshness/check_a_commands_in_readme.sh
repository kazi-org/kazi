#!/usr/bin/env bash
#
# Predicate (a) -- every shipped CLI command appears in README.md (T31.4, ADR-0036).
#
# Source of truth for the command surface: the `@commands` table in
# lib/kazi/cli.ex (see lib.sh for why the table, not a built binary). For each
# shipped command name we require the literal token `kazi <command>` to appear
# in README.md. A shipped command with no `kazi <command>` mention in the README
# is a FAIL, reported with the missing command name.
#
# Usage:
#   .github/scripts/doc_freshness/check_a_commands_in_readme.sh
# Exit: 0 = pass, 1 = fail.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/doc_freshness/lib.sh
source "$HERE/lib.sh"

missing=()
while IFS= read -r cmd; do
  if ! grep -qF "kazi $cmd" "$README"; then
    missing+=("$cmd")
  fi
done < <(df_commands)

if [ ${#missing[@]} -eq 0 ]; then
  df_pass "(a) every shipped CLI command is documented in README.md"
  exit 0
fi

df_fail "(a) shipped CLI commands MISSING from README.md (no 'kazi <cmd>' token):"
for cmd in "${missing[@]}"; do
  printf '        - kazi %s   (expected in %s)\n' "$cmd" "${README#"$DF_ROOT/"}"
done
exit 1

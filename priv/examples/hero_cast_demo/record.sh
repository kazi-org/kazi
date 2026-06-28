#!/usr/bin/env bash
# Reproduce the hero cast (T25.2): record kazi driving a coding agent until a
# failing predicate is objectively true.
#
# This is the EXACT command the committed cast records. It runs the real binary
# against a fresh copy of the broken demo workspace, with the real `claude`
# harness doing the fix. The only post-processing is de-noising: the Ecto/SQLite
# debug lines the released binary logs at :debug are dropped, and the timestamp
# prefix is stripped from kazi's own loop lines. Every line shown is verbatim
# kazi output — run `kazi apply ...` directly to see the same content with the
# DB-layer debug noise included.
#
#   KAZI=kazi ./record.sh                      # filtered run, to a real terminal
#   asciinema rec hero-loop.cast \
#     --output-format asciicast-v2 --overwrite \
#     --window-size 92x20 -i 2.0 -c "KAZI=kazi $(pwd)/record.sh"
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KAZI="${KAZI:-kazi}"
GOAL="$HERE/goal.toml"

DEMO="$(mktemp -d)/demo"
cp -r "$HERE/workspace" "$DEMO"

clear
printf '$ kazi apply hero_cast_demo/goal.toml --workspace ./demo --harness claude\n'

"$KAZI" apply "$GOAL" --workspace "$DEMO" --harness claude 2>&1 | while IFS= read -r line; do
  case "$line" in
    *"kazi.loop goal="*)
      clean="${line#*] }"                 # drop "HH:MM:SS.mmm [debug] "
      clean="${clean% regressions=*}"      # drop trailing regressions/landed/deployed
      printf '%s\n' "$clean"
      ;;
    CONVERGED*|STUCK*|"OVER BUDGET"*|iterations:*|actions:*|"predicate vector:"*|"  [pass]"*|"  [fail]"*)
      printf '%s\n' "$line"
      ;;
  esac
done

printf '\n'

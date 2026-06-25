#!/usr/bin/env bash
# Fake `gist` binary for Tier-2 boundary tests of Kazi.ContextStore.GistCLI
# (T35.2, ADR-0045). Like the other test/support/stub_*.sh fixtures it is NOT a
# lib/ stub (the zero-stub policy applies to lib/ only) — it is a REAL external
# binary that exercises the genuine subprocess + parse path end to end.
#
# Why a fake: the real `gist` in-memory store is per-process, so a `gist index`
# in one invocation is gone by the time a separate `gist search` runs (real
# cross-call persistence needs a PostgreSQL DSN). This fixture is FILE-BACKED via
# $FAKE_GIST_STORE so the cross-call contract (index on one call, search on the
# next, stats accumulate) can be exercised with no Postgres and no network.
#
# It models the subcommands + output formats the adapter shells to and parses,
# matching the real `gist` strings verified against the installed binary:
#   index  -> "Indexed <file>: N chunks (0 code)"
#   search -> matched content, budget-capped, or "No results found."
#   stats  -> "Bytes indexed:  N B" / "Bytes returned: N B" / "Bytes saved: N B"
set -euo pipefail

STORE="${FAKE_GIST_STORE:?FAKE_GIST_STORE must be set}"
mkdir -p "$STORE"
CONTENT="$STORE/content.dat"
IDX="$STORE/indexed_bytes"
RET="$STORE/returned_bytes"
touch "$CONTENT"
[ -f "$IDX" ] || echo 0 >"$IDX"
[ -f "$RET" ] || echo 0 >"$RET"

sub="${1:-}"
shift || true

case "$sub" in
  index)
    files=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --format|--dsn) shift 2 ;;   # flag carrying a value
        --*) shift ;;                # bare flag
        *) files+=("$1"); shift ;;
      esac
    done
    total=0
    for f in "${files[@]}"; do
      bytes=$(wc -c <"$f" | tr -d ' ')
      cat "$f" >>"$CONTENT"
      printf '\n' >>"$CONTENT"
      total=$((total + bytes))
      echo "Indexed $f: 1 chunks (0 code)"
    done
    echo $(( $(cat "$IDX") + total )) >"$IDX"
    ;;

  search)
    query="${1:-}"
    shift || true
    budget=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --budget) budget="$2"; shift 2 ;;
        --limit|--source|--dsn) shift 2 ;;
        --*) shift ;;
        *) shift ;;
      esac
    done

    matches=$(grep -i -F "$query" "$CONTENT" 2>/dev/null || true)
    if [ -z "$matches" ]; then
      for w in $query; do
        m=$(grep -i -F "$w" "$CONTENT" 2>/dev/null || true)
        if [ -n "$m" ]; then matches="$m"; break; fi
      done
    fi

    if [ -z "$matches" ]; then
      echo "No results found."
      exit 0
    fi

    if [ "$budget" -gt 0 ] 2>/dev/null; then
      out=$(printf '%s' "$matches" | head -c "$budget")
    else
      out="$matches"
    fi
    printf '%s\n' "$out"
    rb=$(printf '%s' "$out" | wc -c | tr -d ' ')
    echo $(( $(cat "$RET") + rb )) >"$RET"
    ;;

  stats)
    ib=$(cat "$IDX")
    rb=$(cat "$RET")
    saved=$((ib - rb))
    [ "$saved" -lt 0 ] && saved=0
    echo "Bytes indexed:  ${ib} B"
    echo "Bytes returned: ${rb} B"
    echo "Bytes saved:    ${saved} B (0.0%)"
    echo "Sources:        1"
    echo "Chunks:         1"
    echo "Searches:       1"
    ;;

  *)
    echo "fake_gist: unknown subcommand: ${sub}" >&2
    exit 64
    ;;
esac

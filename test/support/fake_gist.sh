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

sub="${1:-}"
shift || true

# The file-backed store is only needed by the subcommands that read/write the
# index (index/search/stats). `doctor` (T35.8 verify step) inspects the runtime
# only, so it must work WITHOUT $FAKE_GIST_STORE — init the store lazily.
init_store() {
  STORE="${FAKE_GIST_STORE:?FAKE_GIST_STORE must be set}"
  mkdir -p "$STORE"
  CONTENT="$STORE/content.dat"
  IDX="$STORE/indexed_bytes"
  RET="$STORE/returned_bytes"
  touch "$CONTENT"
  [ -f "$IDX" ] || echo 0 >"$IDX"
  [ -f "$RET" ] || echo 0 >"$RET"
}

case "$sub" in
  index)
    init_store
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
      # Record the staged artifact's + its parent dir's permission bits BEFORE
      # the adapter removes the file, so a perms test can assert on them
      # (deep review L4: staged content must not be world-readable).
      dir=$(dirname "$f")
      # GNU stat (`-c`, Linux CI) FIRST, BSD stat (`-f`, macOS) as the fallback:
      # GNU `stat -f` means --file-system (exits 0 with garbage, not perms), so a
      # BSD-first `|| gnu` never falls through on Linux. GNU `-c` genuinely errors
      # on macOS, so `gnu || bsd` picks the right one on both.
      file_mode=$(stat -c "%a" "$f" 2>/dev/null || stat -f "%OLp" "$f")
      dir_mode=$(stat -c "%a" "$dir" 2>/dev/null || stat -f "%OLp" "$dir")
      echo "$file_mode $dir_mode" >"$STORE/last_artifact_perms"
    done
    echo $(( $(cat "$IDX") + total )) >"$IDX"
    ;;

  search)
    init_store
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

  doctor)
    # `kazi init --with-gist` shells `gist doctor` to verify the install before
    # writing project-local config (T35.8). The real binary prints a checklist and
    # exits 0 when the runtime is healthy (a missing DSN is informational, not a
    # failure); the fake mirrors that contract.
    echo "Gist Doctor"
    echo "==========="
    echo "[OK] gist runtime: fake"
    exit 0
    ;;

  stats)
    init_store
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

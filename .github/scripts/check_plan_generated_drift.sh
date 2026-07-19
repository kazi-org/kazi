#!/usr/bin/env bash
#
# check_plan_generated_drift.sh -- the docs/plan-generated.md freshness gate
# (T45.9, ADR-0082).
#
# ADR-0082 (option B on #1554) lands the roadmap's GENERATED view beside the WBS:
# `docs/plan-generated.md` is `kazi plan render` output committed to the repo,
# and it must stay fresh. "Kept fresh" needs a mechanism, not a discipline
# (ADR-0082): this check regenerates the render from the roadmap source and FAILS
# on any byte-drift from the committed file, so a roadmap edit that forgot to
# re-render cannot merge silently.
#
# Renderer: the RELEASE BINARY. `kazi plan render` reads per-goal converged state
# from the read-model, so it needs a booted+migrated app — which the release
# binary provides on boot (ADR-0068 migrate-before-serve) and a bare `mix run`
# does NOT (the dev read-model is unmigrated: "no such table: iterations").
# The committed docs/plan-generated.md is release-binary output, so regenerating
# with the release binary reproduces it byte-for-byte.
#   1. $KAZI_BIN plan render ...   -- an explicit binary path (CI downloads one)
#   2. kazi plan render ...        -- a `kazi` on PATH (local dev)
#
# Usage:   .github/scripts/check_plan_generated_drift.sh
# Exit:    0 = fresh (or no roadmap present), 1 = drift (or no renderer available).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

ROADMAP="$ROOT/docs/roadmap/kazi.roadmap.toml"
COMMITTED="$ROOT/docs/plan-generated.md"

# Both artifacts are part of the ADR-0082 pair; if neither exists this check is
# inert (a repo that has not adopted the generated view). If only one exists,
# that is itself an error -- the pair must land together.
if [ ! -f "$ROADMAP" ] && [ ! -f "$COMMITTED" ]; then
  echo "plan-generated drift: no roadmap + no generated view; nothing to check. PASS."
  exit 0
fi

if [ ! -f "$ROADMAP" ]; then
  echo "plan-generated drift: FAIL -- $COMMITTED exists but its source roadmap $ROADMAP does not." >&2
  exit 1
fi

if [ ! -f "$COMMITTED" ]; then
  echo "plan-generated drift: FAIL -- roadmap $ROADMAP exists but docs/plan-generated.md was never committed. Run: kazi plan render $ROADMAP --out docs/plan-generated.md" >&2
  exit 1
fi

FRESH="$(mktemp)"
trap 'rm -f "$FRESH"' EXIT

render() {
  if [ -n "${KAZI_BIN:-}" ] && [ -x "${KAZI_BIN}" ]; then
    "$KAZI_BIN" plan render "$ROADMAP" --out "$FRESH" >/dev/null 2>&1
  elif command -v kazi >/dev/null 2>&1; then
    kazi plan render "$ROADMAP" --out "$FRESH" >/dev/null 2>&1
  else
    return 127
  fi
}

if ! render; then
  status=$?
  if [ "$status" -eq 127 ]; then
    echo "plan-generated drift: no \`kazi\` binary available (set \$KAZI_BIN or put the release binary on PATH). render needs the release binary's booted read-model." >&2
  else
    echo "plan-generated drift: the renderer FAILED to run (exit $status). The roadmap may be invalid -- run \`kazi lint $ROADMAP\`." >&2
  fi
  exit 1
fi

if diff -u "$COMMITTED" "$FRESH" >/tmp/plan_generated_drift.diff 2>&1; then
  echo "plan-generated drift: docs/plan-generated.md is FRESH (byte-identical to a fresh render). PASS."
  exit 0
fi

echo "plan-generated drift: FAIL -- docs/plan-generated.md is STALE. The roadmap changed but the generated view was not re-rendered." >&2
echo "Fix: kazi plan render $ROADMAP --out docs/plan-generated.md   (then commit)" >&2
echo "--- drift (committed vs fresh) ---" >&2
cat /tmp/plan_generated_drift.diff >&2
exit 1

#!/usr/bin/env bash
#
# doc_freshness.sh -- the doc-freshness predicate RUNNER (T31.4, ADR-0036).
#
# Runs every doc-freshness predicate and prints a PASS/FAIL report with the
# offending location for each failure. This is the DEFINITION-layer entrypoint:
# it is runnable locally and prints a report, but it does NOT gate CI -- wiring
# it into a blocking CI job (warn -> blocking, the E29 pattern) is T31.5.
#
# Predicates (this directory, one script each):
#   (a) check_a_commands_in_readme.sh   every shipped CLI command is in README.md
#   (b) check_b_no_dead_command_refs.sh no live doc names a removed/unknown command
#   (c) check_c_adr_refs_exist.sh       every ADR a doc cites exists in docs/adr/
#   (d) check_d_plan_trimmed.sh         no done+released task lingers in the plan
#   (g) check_g_spec_refs_exist.sh      every spec: pointer in the WBS resolves
#
# SUBSUMED coherence checks (NOT reimplemented here -- referenced/invoked):
#   (E) README <-> website canonical-string coherence (T9.9, ADR-0018):
#         site/scripts/check-coherence.mjs  (`npm --prefix site run check:coherence`)
#   (F) skill / AGENTS.md <-> CLI command-flag coherence (T16.4, ADR-0024):
#         test/kazi/teach_coherence_test.exs  (`mix test test/kazi/teach_coherence_test.exs`)
# These two are existing, separately-owned drift guards. The freshness set folds
# them in by REFERENCE: this runner optionally invokes them when their toolchain
# (node / mix) is present, and otherwise prints how to run them. See
# docs/doc-freshness.md for the full mapping.
#
# Env:
#   SKIP_SUBSUMED=1   do not attempt to invoke (E)/(F); just print the reference.
#   RELEASE_REF=<tag> override the release cutoff used by predicate (d).
#
# Usage:
#   .github/scripts/doc_freshness/doc_freshness.sh
# Exit: 0 if ALL run predicates passed, 1 if any failed. (Predicate (d) is
# EXPECTED to fail until T31.2 trims -- see the report footer.)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

fails=0
run() {
  local label="$1"
  shift
  printf '\n=== %s ===\n' "$label"
  if "$@"; then
    return 0
  fi
  fails=$((fails + 1))
  return 0
}

printf '# doc-freshness predicate set (T31.4, ADR-0036)\n'

run "(a) commands documented in README" "$HERE/check_a_commands_in_readme.sh"
run "(b) no dead/unknown command references in live docs" "$HERE/check_b_no_dead_command_refs.sh"
run "(c) referenced ADRs exist" "$HERE/check_c_adr_refs_exist.sh"
run "(d) plan trimmed of done+released tasks" "$HERE/check_d_plan_trimmed.sh"
run "(g) spec: pointers in the WBS resolve" "$HERE/check_g_spec_refs_exist.sh"

# --- subsumed coherence checks (referenced, not reimplemented) --------------
printf '\n=== (E) README <-> website coherence (T9.9) -- subsumed ===\n'
if [ "${SKIP_SUBSUMED:-0}" = "1" ]; then
  printf 'SKIP  (E) run: npm --prefix site run check:coherence  (site/scripts/check-coherence.mjs)\n'
elif command -v node >/dev/null 2>&1 && [ -f "$ROOT/site/scripts/check-coherence.mjs" ]; then
  if node "$ROOT/site/scripts/check-coherence.mjs"; then
    printf 'PASS  (E) README <-> website canonical strings coherent (T9.9)\n'
  else
    printf 'FAIL  (E) README <-> website coherence (T9.9) -- see output above\n'
    fails=$((fails + 1))
  fi
else
  printf 'SKIP  (E) node not available; run: npm --prefix site run check:coherence\n'
fi

printf '\n=== (F) skill / AGENTS.md <-> CLI coherence (T16.4) -- subsumed ===\n'
if [ "${SKIP_SUBSUMED:-0}" = "1" ]; then
  printf 'SKIP  (F) run: mix test test/kazi/teach_coherence_test.exs\n'
elif command -v mix >/dev/null 2>&1 && [ -d "$ROOT/deps/ecto_sql" ]; then
  # Only judge PASS/FAIL when deps are fetched; an un-fetched worktree would
  # error on deps, not on coherence, so we must not report a false FAIL there.
  if (cd "$ROOT" && mix test test/kazi/teach_coherence_test.exs >/dev/null 2>&1); then
    printf 'PASS  (F) skill / AGENTS.md reference only real commands/flags (T16.4)\n'
  else
    printf 'FAIL  (F) skill / AGENTS.md <-> CLI coherence (T16.4) -- run: mix test test/kazi/teach_coherence_test.exs\n'
    fails=$((fails + 1))
  fi
else
  printf 'SKIP  (F) deps not fetched (mix deps.get); run: mix test test/kazi/teach_coherence_test.exs\n'
fi

# --- report footer ----------------------------------------------------------
printf '\n----------------------------------------------------------------\n'
if [ "$fails" -eq 0 ]; then
  printf 'doc-freshness: ALL predicates passed.\n'
  exit 0
fi
printf 'doc-freshness: %d predicate group(s) FAILED.\n' "$fails"
printf 'NOTE: predicate (d) is EXPECTED to fail until the T31.2 plan-trim runs;\n'
printf '      (a)/(b) may also fail until the README/docs coverage passes land.\n'
printf '      CI enforcement (warn -> blocking) is T31.5, not this definition layer.\n'
exit 1

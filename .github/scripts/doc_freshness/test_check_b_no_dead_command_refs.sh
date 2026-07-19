#!/usr/bin/env bash
#
# test_check_b_no_dead_command_refs.sh -- pins predicate (b)'s command-reference
# detection (fix/checkb-prose-false-positive).
#
# The checker must catch a live doc that still tells a reader to invoke a
# REMOVED verb (`kazi run`/`kazi propose`/`mix kazi.run`, ADR-0032 -- the #1242
# guard class) or a backticked `kazi <cmd>` absent from the shipped table, WHILE
# NOT false-positiving on bare English prose like "Every kazi run already asks".
#
# It drives the REAL checker against synthetic fixture trees via the
# `DF_ROOT` override (lib.sh honours it), so no repo docs are touched.
#
# Usage: .github/scripts/doc_freshness/test_check_b_no_dead_command_refs.sh
# Exit: 0 = all cases pass, 1 = a case regressed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$HERE/check_b_no_dead_command_refs.sh"

fails=0

# Build a minimal fixture repo whose docs/fixture.md holds $1, then run the
# checker against it. Echoes the checker output; return code is the checker's.
run_case() {
  local doc_body="$1"
  local root
  root="$(mktemp -d)"
  mkdir -p "$root/docs" "$root/lib/kazi"

  # A clean README (scanned by the checker too) with no command references.
  printf '# fixture\n\nNothing to see here.\n' >"$root/README.md"

  # A minimal @commands table so df_commands resolves a valid surface
  # (`apply` is the one shipped command these fixtures reference).
  cat >"$root/lib/kazi/cli.ex" <<'ELIXIR'
  @commands [
    %{
      name: "apply",
      summary: "converge a goal",
    },
    %{
      name: "status",
      summary: "read convergence state",
    }
  ]
ELIXIR

  printf '%s\n' "$doc_body" >"$root/docs/fixture.md"

  DF_ROOT="$root" bash "$CHECKER"
  local rc=$?
  rm -rf "$root"
  return $rc
}

# assert_pass <name> <doc-body>: the checker must EXIT 0 (no dead ref).
assert_pass() {
  local name="$1" body="$2" out rc
  out="$(run_case "$body")"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'ok    %s\n' "$name"
  else
    printf 'FAIL  %s (expected pass, got fail)\n%s\n' "$name" "$out"
    fails=$((fails + 1))
  fi
}

# assert_fail <name> <doc-body>: the checker must EXIT 1 (dead ref caught).
assert_fail() {
  local name="$1" body="$2" out rc
  out="$(run_case "$body")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'ok    %s\n' "$name"
  else
    printf 'FAIL  %s (expected fail, got pass)\n%s\n' "$name" "$out"
    fails=$((fails + 1))
  fi
}

# --- prose must NOT trip (the false-positive this fix targets) --------------
assert_pass "prose 'Every kazi run already asks'" \
  'Every kazi run already asks an agent to not leave stubs behind.'
assert_pass "prose 'kazi runs the loop'" \
  'When kazi runs the loop it converges the goal.'
assert_pass "prose 'kazi propose a change'" \
  'You might kazi propose a change in casual speech, but it is prose.'
assert_pass "valid backticked command" \
  'Use `kazi apply` to converge the goal.'

# --- real dead references MUST still trip (do not weaken #1242 guard) -------
assert_fail "kazi run in a fenced code block" \
  "$(printf '```sh\nkazi run goal.toml\n```')"
assert_fail "mix kazi.run in a fence" \
  "$(printf '```sh\nmix kazi.run\n```')"
assert_fail "inline-backticked kazi run" \
  'The old `kazi run` entrypoint is gone.'
assert_fail "bare command line kazi propose" \
  "$(printf 'Run it:\n\n    kazi propose idea\n')"
assert_fail "backticked unknown command (class 2)" \
  'Try `kazi frobnicate` for that.'

if [ "$fails" -eq 0 ]; then
  printf '\nall check_b cases passed\n'
  exit 0
fi
printf '\n%d check_b case(s) regressed\n' "$fails"
exit 1

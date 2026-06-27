#!/usr/bin/env bash
#
# Predicate (b) -- no live doc references a CLI command absent from the code
# (T31.4, ADR-0036).
#
# "Live doc" = README.md plus the user-facing guides under docs/ that describe
# the CURRENT surface. We DELIBERATELY EXCLUDE the archival / history tiers,
# because they legitimately name removed verbs as a matter of record:
#
#   - docs/adr/**          frozen decision records (CLAUDE.md: do not relitigate;
#                          an ADR names the verbs that existed when it was written)
#   - docs/deprecations.md the removal log -- its JOB is to name `kazi run` etc.
#   - docs/devlog.md       append-only session history
#   - docs/plan.md         the WBS, records past task wording
#   - docs/lore.md         append-only invariants/landmines
#   - docs/doc-freshness.md THIS predicate set's own doc -- it quotes removed
#                          verbs and unknown commands as examples, so it is
#                          excluded so its examples do not self-trip (the same
#                          self-exclusion the leak guard applies to its own doc).
#   - docs/oss-gates.md    the doc for the sibling site/doc command guards
#                          (Gate 4/5, T28.4) -- it names `kazi run`/`kazi propose`/
#                          `kazi frobnicate` as EXAMPLES of what those guards
#                          catch, exactly like doc-freshness.md. Gate 5's own
#                          scanner already self-excludes this file; this guard
#                          must match, or the example list self-trips (T31.7).
#
# Two failure classes are reported, each with file:line:
#   1. A KNOWN-REMOVED verb token: `kazi run`, `kazi propose`, `mix kazi.run`
#      (removed in v1.0.0, ADR-0032 -- see docs/deprecations.md). Matched on a
#      word boundary so prose like "kazi runs it" does NOT trip.
#   2. A backtick-quoted `` `kazi <cmd>` `` whose <cmd> is NOT in the shipped
#      command table (lib/kazi/cli.ex @commands). Catches future drift, e.g.
#      `kazi adopt` (a conceptual name, not a shipped command). `kazi mcp` IS a
#      shipped verb as of T33.1/ADR-0044, so it now passes this check.
#
# Usage:
#   .github/scripts/doc_freshness/check_b_no_dead_command_refs.sh
# Exit: 0 = pass, 1 = fail.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/scripts/doc_freshness/lib.sh
source "$HERE/lib.sh"

# Live docs to scan: README + every docs/*.md EXCEPT the history tiers, and no
# docs/adr/** (find is bounded to the top level, so the adr/ subdir is skipped).
# Built without mapfile for bash 3.2 portability (matches the sibling guards).
LIVE_DOCS=()
while IFS= read -r f; do
  LIVE_DOCS+=("$f")
done < <(
  {
    printf '%s\n' "$README"
    find "$DF_ROOT/docs" -maxdepth 1 -name '*.md' \
      ! -name 'deprecations.md' \
      ! -name 'devlog.md' \
      ! -name 'plan.md' \
      ! -name 'lore.md' \
      ! -name 'doc-freshness.md' \
      ! -name 'oss-gates.md'
  } | sort -u
)

rel() { printf '%s' "${1#"$DF_ROOT/"}"; }

valid_cmds="$(df_commands)"
offenders=0

# --- class 1: known-removed verb tokens -----------------------------------
# Word-boundary match: `kazi run` / `kazi propose` / `mix kazi.run` not followed
# by a word char (so "runs"/"proposes" are safe).
removed_re='(kazi (run|propose)|mix kazi\.run)([^a-zA-Z]|$)'
for f in "${LIVE_DOCS[@]}"; do
  [ -f "$f" ] || continue
  while IFS=: read -r lineno _; do
    line_text="$(sed -n "${lineno}p" "$f")"
    df_fail "(b) removed verb referenced -> $(rel "$f"):${lineno}: ${line_text#"${line_text%%[![:space:]]*}"}"
    offenders=$((offenders + 1))
  done < <(grep -nE "$removed_re" "$f" || true)
done

# --- class 2: backtick `kazi <cmd>` not in the shipped table ---------------
for f in "${LIVE_DOCS[@]}"; do
  [ -f "$f" ] || continue
  while IFS=: read -r lineno match; do
    cmd="${match#\`kazi }"
    if ! grep -qxF "$cmd" <<<"$valid_cmds"; then
      df_fail "(b) unknown command \`kazi ${cmd}\` -> $(rel "$f"):${lineno} (not in lib/kazi/cli.ex @commands)"
      offenders=$((offenders + 1))
    fi
  done < <(grep -noE '`kazi [a-z][a-z-]*' "$f" || true)
done

if [ "$offenders" -eq 0 ]; then
  df_pass "(b) no live doc references a command absent from the CLI"
  exit 0
fi
exit 1

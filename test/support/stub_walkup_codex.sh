#!/usr/bin/env bash
# T72.5: reproduces Codex's documented instruction-file walk-up (ADR-0086
# context: "Codex does the same for AGENTS.md") as a REAL, separately-
# executed process reading REAL files from a REAL cwd. See
# stub_walkup_claude.sh for the Claude Code counterpart, the rationale for
# using a real external stub rather than a lib/ reimplementation, and why
# bash arrays are avoided (macOS bash 3.2 + `set -u`).
#
# Walks from `pwd` up to the filesystem root, printing every `AGENTS.md` it
# finds along the way, concatenated. Codex never reads `CLAUDE.md`, so this
# needs no symlink at all -- it reads the `AGENTS.md` file T72.4
# (`Kazi.Plan.Tree`) always writes directly.
set -euo pipefail

dir="$(pwd)"
while :; do
  if [ -f "$dir/AGENTS.md" ]; then
    cat "$dir/AGENTS.md"
  fi
  parent="$(dirname "$dir")"
  if [ "$parent" = "$dir" ]; then
    break
  fi
  dir="$parent"
done

exit 0

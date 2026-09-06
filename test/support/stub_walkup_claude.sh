#!/usr/bin/env bash
# T72.5: reproduces Claude Code's documented instruction-file walk-up
# (ADR-0086 context: "Claude Code walks up from the working directory
# merging every CLAUDE.md it finds") as a REAL, separately-executed
# process reading REAL files from a REAL cwd -- not a reimplementation
# inside kazi's own lib/ code (zero-stub policy applies to lib/ only; this
# is a stand-in external binary, same pattern as test/support/stub_claude.sh).
#
# Walks from `pwd` up to the filesystem root, printing every `CLAUDE.md` it
# finds along the way, concatenated. Uses a plain `cat`, which follows a
# symlink dirent transparently at the OS level (standard POSIX `open()`
# semantics) -- this is the exact question T72.5 needs answered for the
# `CLAUDE.md -> AGENTS.md` symlink T72.4 (`Kazi.Plan.Tree`) creates.
#
# Avoids bash arrays entirely -- macOS ships bash 3.2, whose `set -u`
# treats an EMPTY array's `"${arr[@]}"` expansion as an unbound-variable
# error (fixed only in bash 4.4+).
set -euo pipefail

dir="$(pwd)"
while :; do
  if [ -f "$dir/CLAUDE.md" ]; then
    cat "$dir/CLAUDE.md"
  fi
  parent="$(dirname "$dir")"
  if [ "$parent" = "$dir" ]; then
    break
  fi
  dir="$parent"
done

exit 0

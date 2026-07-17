#!/usr/bin/env python3
"""Lore L-NNNN id tooling (T56.3, issue #1220).

Two modes:

  lore_ids.py --check [path]   Fail (exit 1) when two lore entries share an
                               L-NNNN heading id. The CI guard: a PR that
                               reintroduces a duplicate id fails here.
  lore_ids.py --next [path]    Print the next free L-NNNN id. Computed against
                               the FETCHED remote state of docs/lore.md
                               (git fetch origin <branch>, then
                               origin/<branch>:docs/lore.md) UNIONED with the
                               local file — never the local tree alone, because
                               parallel pool tasks and merged-but-unpulled work
                               make local numbering stale (the same
                               sequential-numbering hazard the /apply teammate
                               contract guards for migrations).

Ids are read from entry HEADINGS only (`### L-NNNN ...`); in-body citations of
another entry's id are not allocations.
"""

import argparse
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

HEADING_ID = re.compile(r"^### (L-\d{4,})\b", re.MULTILINE)
DEFAULT_PATH = "docs/lore.md"


def heading_ids(text):
    return HEADING_ID.findall(text)


def duplicates(text):
    return sorted(i for i, n in Counter(heading_ids(text)).items() if n > 1)


def remote_text(repo_root, path, remote="origin", branch="main"):
    """The fetched-remote lore content, or None when unreachable (offline)."""
    subprocess.run(
        ["git", "-C", str(repo_root), "fetch", "--quiet", remote, branch],
        check=False,
        capture_output=True,
    )
    show = subprocess.run(
        ["git", "-C", str(repo_root), "show", f"{remote}/{branch}:{path}"],
        capture_output=True,
        text=True,
    )
    return show.stdout if show.returncode == 0 else None


def next_id(local_file, repo_root, remote="origin", branch="main"):
    ids = set(heading_ids(local_file.read_text()))
    remote_content = remote_text(repo_root, DEFAULT_PATH, remote, branch)
    if remote_content is not None:
        ids |= set(heading_ids(remote_content))
    top = max((int(i.split("-")[1]) for i in ids), default=0)
    return f"L-{top + 1:04d}"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="fail on duplicate heading ids")
    mode.add_argument("--next", action="store_true", help="print the next free id")
    ap.add_argument("path", nargs="?", default=DEFAULT_PATH)
    ap.add_argument("--remote", default="origin")
    ap.add_argument("--branch", default="main")
    args = ap.parse_args()

    local = Path(args.path)
    if not local.exists():
        print(f"lore_ids: {local} not found", file=sys.stderr)
        return 2

    if args.check:
        dups = duplicates(local.read_text())
        if dups:
            print(f"lore_ids: DUPLICATE lore ids in {local}: {', '.join(dups)}")
            print("Renumber the later entry to the next free id (`lore_ids.py --next`).")
            return 1
        print(f"lore_ids: no duplicate ids in {local}.")
        return 0

    repo_root = local.resolve().parent.parent if local.name == "lore.md" else Path.cwd()
    print(next_id(local, repo_root, args.remote, args.branch))
    return 0


if __name__ == "__main__":
    sys.exit(main())

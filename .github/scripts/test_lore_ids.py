#!/usr/bin/env python3
"""Fixture tests for lore_ids.py (T56.3 acceptance). Run: python3 test_lore_ids.py

Pins: the duplicate check fails on a synthetic duplicate and passes clean; the
next-id allocator computes against the FETCHED remote state, not the local tree
alone (a stale local clone still allocates above the remote max)."""

import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "lore_ids.py"


def run(*args, cwd=None):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args], capture_output=True, text=True, cwd=cwd
    )


def lore(*nums):
    return "# Lore\n\n" + "\n".join(f"### L-{n:04d} #tag -- entry {n}\n\nbody citing L-0001.\n" for n in nums)


def git(cwd, *args):
    subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True)


def test_check():
    with tempfile.TemporaryDirectory() as td:
        clean = Path(td) / "clean.md"
        clean.write_text(lore(1, 2, 3))
        r = run("--check", str(clean))
        assert r.returncode == 0, r.stdout + r.stderr

        dup = Path(td) / "dup.md"
        dup.write_text(lore(1, 2, 2))
        r = run("--check", str(dup))
        assert r.returncode == 1, r.stdout + r.stderr
        assert "L-0002" in r.stdout
    print("ok: --check passes clean, fails a duplicate")


def test_next_uses_fetched_remote():
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        # Remote: lore up to L-0050.
        origin = td / "origin"
        origin.mkdir()
        git(origin, "init", "-q", "-b", "main")
        git(origin, "config", "user.email", "t@example.com")
        git(origin, "config", "user.name", "t")
        (origin / "docs").mkdir()
        (origin / "docs/lore.md").write_text(lore(1, 2, 45))
        git(origin, "add", "."), git(origin, "commit", "-qm", "seed")
        # Local clone, then remote advances to L-0050 WITHOUT a local pull:
        local = td / "local"
        git(td, "clone", "-q", str(origin), str(local))
        (origin / "docs/lore.md").write_text(lore(1, 2, 45, 50))
        git(origin, "add", "."), git(origin, "commit", "-qm", "advance")
        # Stale local tree still tops out at 45; the allocator must fetch and
        # answer above the REMOTE max (51), not the local max (46).
        r = run("--next", "docs/lore.md", cwd=local)
        assert r.returncode == 0, r.stdout + r.stderr
        assert r.stdout.strip() == "L-0051", r.stdout
    print("ok: --next allocates above the fetched remote max on a stale local tree")


if __name__ == "__main__":
    test_check()
    test_next_uses_fetched_remote()
    print("all lore_ids fixture tests passed")

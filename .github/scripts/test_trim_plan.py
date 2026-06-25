#!/usr/bin/env python3
"""Fixture tests for trim_plan.py (T31.2 acceptance). Run: python3 test_trim_plan.py

Pins: a done+released epic is archived VERBATIM (lossless) with a pointer; a
partially-done epic and an unreleased/undated epic are left untouched; re-running
is a no-op. No git required — the fixture is a plain tempdir and trim_plan's
`git mv` falls back to a plain move.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "trim_plan.py"
CUTOFF = "2026-01-10"

MASTER = """\
# Plan

## Checkable Work Breakdown

### E1 -- Done epic (P1) -> plans/E1.md
### E2 -- Open epic (P1) -> plans/E2.md
### E3 -- Undated epic (P1) -> plans/E3.md

## Risk Register

- nothing here
"""
E1 = """\
**Component:** infra

- [x] T1.1 first thing.  Done: 2026-01-05  verifies: [UC-1]
- [x] T1.2 second thing.  Done: 2026-01-08  verifies: [UC-1]
"""
E2 = """\
- [x] T2.1 done part.  Done: 2026-01-05
- [ ] T2.2 still open.  Est: 1h
"""
E3 = """\
- [x] T3.1 done but UNDATED (cannot prove release coverage).
"""


def setup(tmp):
    (tmp / "docs" / "plans").mkdir(parents=True)
    (tmp / "docs" / "plan.md").write_text(MASTER)
    (tmp / "docs" / "plans" / "E1.md").write_text(E1)
    (tmp / "docs" / "plans" / "E2.md").write_text(E2)
    (tmp / "docs" / "plans" / "E3.md").write_text(E3)


def run(tmp, *extra):
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--root", str(tmp), "--release-date", CUTOFF, *extra],
        capture_output=True, text=True,
    )


def check(cond, msg):
    if not cond:
        print(f"FAIL: {msg}")
        sys.exit(1)
    print(f"ok: {msg}")


def main():
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        setup(tmp)

        # Dry-run names only the done+released epic.
        dry = run(tmp)
        check("E1" in dry.stdout and "E2" not in dry.stdout and "E3" not in dry.stdout,
              "dry-run flags only the done+released epic (E1)")

        # Apply.
        applied = run(tmp, "--apply")
        check(applied.returncode == 0, "apply exits 0")

        plan = (tmp / "docs" / "plan.md").read_text()
        archived = tmp / "docs" / "plans" / "archive" / "E1.md"

        check(archived.exists(), "E1 file moved into docs/plans/archive/")
        check(archived.read_text() == E1, "archived E1 is BYTE-IDENTICAL to the original (lossless)")
        check(not (tmp / "docs" / "plans" / "E1.md").exists(), "E1 removed from the live plans dir")
        check("### E1 -- Done epic (P1) -> plans/E1.md" not in plan, "E1's WBS pointer is gone")
        check("## Archived epics" in plan, "an Archived epics section exists")
        check("plans/archive/E1.md" in plan, "the Archived section points at the archived file")

        # Safety: E2 (open) + E3 (undated) untouched, still in the live WBS.
        check((tmp / "docs" / "plans" / "E2.md").exists(), "E2 (open) left untouched")
        check((tmp / "docs" / "plans" / "E3.md").exists(), "E3 (undated) left untouched")
        check("-> plans/E2.md" in plan and "-> plans/E3.md" in plan,
              "E2/E3 still have live WBS pointers")

        # Idempotent: a second apply changes nothing.
        before = plan
        again = run(tmp, "--apply")
        check(again.returncode == 0, "re-run exits 0")
        check((tmp / "docs" / "plan.md").read_text() == before, "re-run is a no-op (idempotent)")

    print("\nALL PASS")


if __name__ == "__main__":
    main()

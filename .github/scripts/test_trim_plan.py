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

- [x] T1.1 first thing.  Done: 2026-01-05  verifies: [UC-1]  spec: docs/specs/e1-thing.feature
- [x] T1.2 second thing.  Done: 2026-01-08  verifies: [UC-1]
"""
E1_FEATURE = "Feature: E1 thing\n  Scenario: it works\n    Then ok\n"
E1_NOTE = "# E1 thing — proposal note\n"
OTHER_FEATURE = "Feature: Unreferenced\n  Scenario: untouched\n    Then ok\n"
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
    # T40.4 fixtures: E1's task references a behavior spec (+ its paired note);
    # an unreferenced spec must stay put.
    (tmp / "docs" / "specs").mkdir(parents=True)
    (tmp / "docs" / "specs" / "e1-thing.feature").write_text(E1_FEATURE)
    (tmp / "docs" / "specs" / "e1-thing.md").write_text(E1_NOTE)
    (tmp / "docs" / "specs" / "other.feature").write_text(OTHER_FEATURE)


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

        # T40.4: E1's referenced behavior spec + its paired note moved to
        # docs/specs/archive/ verbatim; the unreferenced spec is untouched.
        specs_archive = tmp / "docs" / "specs" / "archive"
        check((specs_archive / "e1-thing.feature").exists(), "referenced .feature moved to docs/specs/archive/")
        check((specs_archive / "e1-thing.feature").read_text() == E1_FEATURE, "archived .feature is byte-identical (lossless)")
        check((specs_archive / "e1-thing.md").exists(), "the paired .md note moved with its .feature")
        check(not (tmp / "docs" / "specs" / "e1-thing.feature").exists(), "referenced .feature removed from the live specs dir")
        check((tmp / "docs" / "specs" / "other.feature").exists(), "an UNreferenced spec is left untouched")
        check(not (specs_archive / "other.feature").exists(), "the unreferenced spec was NOT archived")
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

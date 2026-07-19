#!/usr/bin/env python3
"""T31.2 / ADR-0036 Layer 1 — deterministic, lossless plan trim.

Archives an epic OUT of the live plan ONLY when it is fully closed (no open or
blocked tasks) AND release-covered (every `[x]` task's `Done:` date is on or
before the newest release tag). Mechanical, not an LLM: it moves the epic's file
verbatim to `docs/plans/archive/`, drops the epic's `### ENN ... -> plans/ENN.md`
pointer from the Checkable Work Breakdown, and records a one-line entry in an
`## Archived epics` section of the master `docs/plan.md`.

Properties (the T31.2 acceptance):
  * LOSSLESS — the archived file is byte-for-byte the original epic file.
  * IDEMPOTENT — an epic already archived (file under archive/, no live pointer)
    is skipped; re-running changes nothing.
  * REVERSIBLE — every move is a plain `git mv` + a pointer edit.
  * SAFE — a partially-done, blocked, or unreleased epic is left untouched.

Usage:
  trim_plan.py                 # dry-run: print what WOULD be archived
  trim_plan.py --apply         # perform the trim
  trim_plan.py --release-date YYYY-MM-DD   # override the release cutoff
  trim_plan.py --root <repo>   # repo root (default: cwd)
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

WBS_RE = re.compile(r"^## .*Checkable Work Breakdown")
H2_RE = re.compile(r"^## ")
# A WBS epic pointer: `### ENN -- Title ... -> plans/ENN.md`
POINTER_RE = re.compile(r"^(#{3}\s+(E\d+[A-Za-z]?)\b.*?)\s+(?:->|→)\s+(plans/\S+\.md)\b.*$")
OPEN_RE = re.compile(r"^- \[ \] [TS][0-9]")
BLOCKED_RE = re.compile(r"\bblocked:\s+\S")
DONE_TASK_RE = re.compile(r"^- \[x\] [TS][0-9]")
DONE_DATE_RE = re.compile(r"\bDone:\s*(\d{4}-\d{2}-\d{2})")
TASK_RE = re.compile(r"^- \[[ x~]\] [TS][0-9]")
ARCHIVED_HEADER = "## Archived epics"
# A task's optional behavior-spec pointer (ADR-0050): `spec: docs/specs/<slug>.feature`.
# Same shape parse_plan.py recognises. When an epic archives, its referenced
# specs move with it (T40.4).
SPEC_RE = re.compile(r"(?<![-\w])spec:\s+([^\s<>]+\.(?:feature|md))")


def spec_paths(epic_text):
    """The docs/specs files an epic's tasks reference via `spec:`, each paired
    with its sibling note (`foo.feature` <-> `foo.md`) so the pair archives
    together (T40.4/ADR-0050). Order-preserving, de-duplicated."""
    out = []
    for m in SPEC_RE.finditer(epic_text):
        ref = m.group(1)
        stem, _, ext = ref.rpartition(".")
        pair = f"{stem}.md" if ext == "feature" else f"{stem}.feature"
        for p in (ref, pair):
            if p not in out:
                out.append(p)
    return out


def archive_spec_file(root, rel_path, dest_dir):
    """Move one docs/specs file verbatim to docs/specs/archive/ (git mv to keep
    history + reversibility; plain move fallback). A missing file (e.g. the
    optional paired .md) is skipped. Returns True if it moved something."""
    src = root / rel_path
    if not src.exists():
        return False
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / src.name
    if subprocess.run(["git", "-C", str(root), "mv", str(src), str(dest)]).returncode != 0:
        src.replace(dest)
    return True


def newest_release_date(root: Path) -> str | None:
    tag = subprocess.run(
        ["git", "-C", str(root), "tag", "--list", "v*", "--sort=-creatordate"],
        capture_output=True, text=True,
    ).stdout.splitlines()
    if not tag:
        return None
    return subprocess.run(
        ["git", "-C", str(root), "log", "-1", "--format=%cs", tag[0]],
        capture_output=True, text=True,
    ).stdout.strip() or None


def epic_trimmable(epic_lines, release_date):
    """A (reason-or-None) verdict for one epic file's body."""
    tasks = [l for l in epic_lines if TASK_RE.match(l)]
    if not tasks:
        return "no tasks"
    if any(OPEN_RE.match(l) for l in epic_lines):
        return "has an open task"
    if any(BLOCKED_RE.search(l) for l in epic_lines):
        return "has a blocked task"
    done_dates = []
    for l in epic_lines:
        if DONE_TASK_RE.match(l):
            m = DONE_DATE_RE.search(l)
            if not m:
                return "a [x] task has no Done: date"
            done_dates.append(m.group(1))
    if any(d > release_date for d in done_dates):
        return "a [x] task post-dates the newest release (not yet released)"
    return None  # trimmable


def parse_master(root: Path):
    plan = root / "docs" / "plan.md"
    lines = plan.read_text().splitlines()
    start = next((i for i, l in enumerate(lines) if WBS_RE.match(l)), None)
    if start is None:
        sys.exit("ERROR: no Checkable Work Breakdown section")
    end = next((i for i in range(start + 1, len(lines)) if H2_RE.match(lines[i])), len(lines))
    return plan, lines, start, end


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--release-date")
    ap.add_argument("--root", default=".")
    args = ap.parse_args()
    root = Path(args.root).resolve()

    release_date = args.release_date or newest_release_date(root)
    if not release_date:
        sys.exit("ERROR: no release tag found; cannot evaluate release coverage")

    plan, lines, wbs_start, wbs_end = parse_master(root)
    archive_dir = root / "docs" / "plans" / "archive"

    trimmable, skipped = [], []
    for i in range(wbs_start + 1, wbs_end):
        m = POINTER_RE.match(lines[i])
        if not m:
            continue
        heading, eid, rel = m.group(1).rstrip(), m.group(2), m.group(3)
        epic_file = root / "docs" / rel
        if not epic_file.exists():
            continue  # already archived / dangling
        reason = epic_trimmable(epic_file.read_text().splitlines(), release_date)
        (skipped if reason else trimmable).append((i, heading, eid, rel, epic_file, reason))

    if not trimmable:
        print(f"No epic is trimmable (release cutoff {release_date}). "
              f"{len(skipped)} live epic(s) left untouched.")
        return

    print(f"Trimmable (cutoff {release_date}): " + ", ".join(t[2] for t in trimmable))
    if not args.apply:
        print("dry-run; pass --apply to archive.")
        return

    archive_dir.mkdir(parents=True, exist_ok=True)
    specs_archive_dir = root / "docs" / "specs" / "archive"
    archived_entries = []
    drop_idxs = set()
    moved_specs = 0
    for i, heading, eid, rel, epic_file, _ in trimmable:
        # T40.4 (ADR-0050 / ADR-0036 L1): read the epic body BEFORE the move so
        # its `spec:` references still resolve, then relocate each referenced
        # behavior spec (+ its paired note) to docs/specs/archive/ verbatim --
        # the same lossless git mv the epic file itself gets.
        specs = spec_paths(epic_file.read_text())
        dest = archive_dir / epic_file.name
        # git mv keeps history + is reversible; fall back to a plain move.
        if subprocess.run(["git", "-C", str(root), "mv", str(epic_file), str(dest)]).returncode != 0:
            epic_file.replace(dest)
        for rel_spec in specs:
            if archive_spec_file(root, rel_spec, specs_archive_dir):
                moved_specs += 1
        drop_idxs.add(i)
        archived_entries.append(f"- {heading[4:]} (archived {release_date}) -> plans/archive/{epic_file.name}")

    # Rebuild the master: drop the trimmed pointers, append the Archived section.
    out = [l for j, l in enumerate(lines) if j not in drop_idxs]
    if ARCHIVED_HEADER not in out:
        out += ["", ARCHIVED_HEADER, "",
                "Fully-done, released epics, trimmed from the live WBS (T31.2/ADR-0036 L1).",
                "Their bodies live verbatim under `docs/plans/archive/`.", ""]
    hdr = out.index(ARCHIVED_HEADER)
    insert_at = next((k for k in range(hdr + 1, len(out)) if H2_RE.match(out[k])), len(out))
    out[insert_at:insert_at] = archived_entries
    plan.write_text("\n".join(out).rstrip("\n") + "\n")
    specs_note = f" (+{moved_specs} behavior spec file(s) to docs/specs/archive/)" if moved_specs else ""
    print(f"Archived {len(trimmable)} epic(s) to {archive_dir.relative_to(root)}.{specs_note}")


if __name__ == "__main__":
    main()

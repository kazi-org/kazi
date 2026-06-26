#!/usr/bin/env python3
"""Fixture tests for extract_knowledge.py (T31.3 acceptance). Run: python3 test_extract_knowledge.py

Pins the ADR-0036 Layer-2 contract:
  (a) extraction PROPOSES tier-routed edits per the ADR-0036 map
      (invariant/landmine->lore, finding/benchmark->devlog, decision->adr, architecture->concept);
  (b) nothing is removed from the archive — the archived epic is byte-identical
      before and after, even with --apply;
  (c) a mis-route loses NO knowledge — the nugget text still lives in the archive
      (the lossless backstop), regardless of where routing sent it;
  (d) the tier map routes architecture to concept.md, NOT design.md;
  plus: dry-run writes nothing, and --apply is idempotent (re-run is a no-op).

No git required — a plain tempdir mirroring the split-plan layout.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "extract_knowledge.py"

# An archived epic carrying one nugget of each ADR-0036 class.
ARCHIVED_EPIC = """\
**Component:** docs lifecycle

- [x] T9.1 ship the thing.  Done: 2026-01-05  verifies: [UC-9]
- [x] T9.2 wire the other thing.  Done: 2026-01-06

Nugget(invariant): the read-model repo must always be started before any status command runs.
Nugget(landmine): never cap the claude draft at 3 minutes -- it silently times out the diagnostic.
Nugget(finding): root cause was the Burrito binary booting the CLI before supervising the repo.
Nugget(benchmark): the tool-surface knob measured a ~2x token win on the within-reach fixture.
Nugget(decision): we chose to keep the trim deterministic and the extraction LLM-gated, not merged.
Nugget(architecture): the doc lifecycle is a three-layer subsystem driven as a kazi standing goal.
"""

LORE = "# kazi lore\n\nAppend-only.\n\n## Existing\n\n### L-0016 #x -- prior\nbody\n"
DEVLOG = "# kazi devlog\n\nNewest at top.\n\n## 2026-01-01 — older entry\n\nstuff\n"
CONCEPT = "# kazi — Concept & Architecture\n\n## 1. Intro\n\nnarrative.\n"
ADR = "# ADR 0047: prior decision\n\n## Status\nAccepted\n"


def setup(tmp):
    (tmp / "docs" / "plans" / "archive").mkdir(parents=True)
    (tmp / "docs" / "adr").mkdir(parents=True)
    (tmp / "docs" / "plan.md").write_text(
        "# Plan\n\n## Archived epics\n\n- E9 (archived) -> plans/archive/E9.md\n")
    (tmp / "docs" / "plans" / "archive" / "E9.md").write_text(ARCHIVED_EPIC)
    (tmp / "docs" / "lore.md").write_text(LORE)
    (tmp / "docs" / "devlog.md").write_text(DEVLOG)
    (tmp / "docs" / "concept.md").write_text(CONCEPT)
    (tmp / "docs" / "adr" / "0047-prior.md").write_text(ADR)


def run(tmp, *extra):
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--root", str(tmp), *extra],
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
        archive = tmp / "docs" / "plans" / "archive" / "E9.md"
        original = archive.read_text()

        # --- Dry-run PROPOSES tier-routed edits per the ADR-0036 map (a) -----
        dry = run(tmp, "--latest")
        check(dry.returncode == 0, "dry-run on --latest exits 0")
        out = dry.stdout
        check("[docs/lore.md]  invariant" in out, "invariant routed to lore.md")
        check("[docs/lore.md]  landmine" in out, "landmine routed to lore.md")
        check("[docs/devlog.md]  finding" in out, "finding routed to devlog.md")
        check("[docs/devlog.md]  benchmark" in out, "benchmark routed to devlog.md")
        check("[docs/adr/]  decision" in out, "decision routed to docs/adr/")
        check("[docs/concept.md]  architecture" in out, "architecture routed to concept.md")

        # (d) architecture -> concept.md, never design.md
        check("design.md" not in out, "tier map never mentions design.md (architecture->concept.md)")

        # Dry-run writes NOTHING.
        check((tmp / "docs" / "lore.md").read_text() == LORE, "dry-run leaves lore.md unwritten")
        check((tmp / "docs" / "devlog.md").read_text() == DEVLOG, "dry-run leaves devlog.md unwritten")
        check(archive.read_text() == original, "dry-run leaves the archive byte-identical")

        # --- Apply: writes each tier in house format ------------------------
        applied = run(tmp, "--epic", "docs/plans/archive/E9.md", "--apply")
        check(applied.returncode == 0, "apply exits 0")

        lore = (tmp / "docs" / "lore.md").read_text()
        devlog = (tmp / "docs" / "devlog.md").read_text()
        concept = (tmp / "docs" / "concept.md").read_text()
        check("L-0017" in lore and "must always be started" in lore,
              "lore gets the invariant with the next L-id")
        check("silently times out" in lore, "lore gets the landmine too")
        check("Burrito binary" in devlog and "~2x token win" in devlog,
              "devlog gets the finding + benchmark")
        check("three-layer subsystem" in concept, "concept gets the architecture nugget")
        adrs = list((tmp / "docs" / "adr").glob("*.md"))
        new_adr = [p for p in adrs if "0047-prior" not in p.name]
        check(len(new_adr) == 1 and "0048" in new_adr[0].name,
              "decision becomes a NEW proposed ADR (next number 0048)")
        check("Proposed" in new_adr[0].read_text(), "the new ADR is Status: Proposed (gated, not Accepted)")

        # (b) NOTHING removed from the archive — byte-identical after --apply.
        check(archive.read_text() == original, "archive is byte-identical after --apply (nothing removed)")

        # (c) mis-route loses no knowledge: every nugget's text still lives in
        #     the archive, which is the lossless backstop.
        for fragment in ("must always be started", "silently times out", "Burrito binary",
                         "~2x token win", "trim deterministic", "three-layer subsystem"):
            check(fragment in archive.read_text(),
                  f"archive still holds the nugget text ({fragment[:20]!r}) — no knowledge lost")

        # --- Idempotent: a second --apply changes nothing -------------------
        snap = {p: (tmp / "docs" / p).read_text() for p in ("lore.md", "devlog.md", "concept.md")}
        adr_count = len(list((tmp / "docs" / "adr").glob("*.md")))
        again = run(tmp, "--epic", "docs/plans/archive/E9.md", "--apply")
        check(again.returncode == 0, "re-run exits 0")
        check(all((tmp / "docs" / p).read_text() == snap[p] for p in snap),
              "re-run does not duplicate entries (idempotent via kx: marker)")
        check(len(list((tmp / "docs" / "adr").glob("*.md"))) == adr_count,
              "re-run creates no duplicate ADR")

    print("\nALL PASS")


if __name__ == "__main__":
    main()

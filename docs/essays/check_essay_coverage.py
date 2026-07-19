#!/usr/bin/env python3
"""Essay coverage + freshness checker (docs/essays/README.md).

Deterministic, stdlib-only. Reads features.toml (the significant-feature
manifest) and every essay's frontmatter, then reports:

  - coverage:  % of manifest features covered by >= 1 essay
  - staleness: essays whose anchors have a git commit NEWER than `reviewed:`
  - integrity: essays covering unknown feature ids, or anchors that don't exist

Modes:
  (no flags)          human-readable report, exit 0 always
  --check             exit 1 on any integrity error or stale essay
  --metric coverage   print the bare coverage percentage (kazi ratchet, higher_better)
  --metric stale      print the bare stale-essay count (kazi ratchet to 0, lower_better)

Run from anywhere; paths self-locate relative to this file's repo.
"""

import re
import subprocess
import sys
import tomllib
from datetime import date
from pathlib import Path

ESSAYS_DIR = Path(__file__).resolve().parent
REPO_ROOT = ESSAYS_DIR.parent.parent
NON_ESSAYS = {"README.md", "TEMPLATE.md"}


def load_features():
    with open(ESSAYS_DIR / "features.toml", "rb") as f:
        data = tomllib.load(f)
    return {feat["id"]: feat for feat in data.get("feature", [])}


def parse_frontmatter(path):
    """Minimal YAML frontmatter parse: covers (inline list), reviewed, status."""
    text = path.read_text(encoding="utf-8")
    m = re.match(r"\A---\n(.*?)\n---\n", text, re.DOTALL)
    if not m:
        return None
    fm = {}
    for line in m.group(1).splitlines():
        kv = re.match(r"^(\w+):\s*(.*)$", line)
        if not kv:
            continue
        key, val = kv.group(1), kv.group(2).strip()
        if key == "covers":
            fm["covers"] = [x.strip() for x in val.strip("[]").split(",") if x.strip()]
        else:
            fm[key] = val.strip("\"'")
    return fm


def last_commit_date(path):
    """The date (YYYY-MM-DD) of the newest commit touching path, or None."""
    out = subprocess.run(
        ["git", "log", "-1", "--format=%cs", "--", str(path)],
        cwd=REPO_ROOT, capture_output=True, text=True,
    )
    val = out.stdout.strip()
    return date.fromisoformat(val) if out.returncode == 0 and val else None


def main():
    args = sys.argv[1:]
    features = load_features()
    errors, stale, covered = [], [], set()

    for path in sorted(ESSAYS_DIR.glob("*.md")):
        if path.name in NON_ESSAYS:
            continue
        fm = parse_frontmatter(path)
        if fm is None:
            errors.append(f"{path.name}: missing frontmatter")
            continue
        ids = fm.get("covers", [])
        if not ids:
            errors.append(f"{path.name}: frontmatter has no covers: list")
        for fid in ids:
            if fid not in features:
                errors.append(f"{path.name}: covers unknown feature id {fid!r}")
                continue
            covered.add(fid)
        try:
            reviewed = date.fromisoformat(fm.get("reviewed", ""))
        except ValueError:
            errors.append(f"{path.name}: missing/invalid reviewed: date")
            continue
        for fid in ids:
            for anchor in features.get(fid, {}).get("anchors", []):
                apath = REPO_ROOT / anchor
                if not apath.exists():
                    errors.append(f"features.toml: anchor {anchor} does not exist")
                    continue
                changed = last_commit_date(apath)
                if changed and changed > reviewed:
                    stale.append(
                        f"{path.name}: anchor {anchor} changed {changed}, "
                        f"essay reviewed {reviewed}"
                    )

    pct = round(100.0 * len(covered) / len(features), 1) if features else 100.0

    if "--metric" in args:
        which = args[args.index("--metric") + 1]
        print(pct if which == "coverage" else len(stale))
        return 0
    if "--check" in args:
        for line in errors + stale:
            print(f"FAIL {line}", file=sys.stderr)
        return 1 if (errors or stale) else 0

    print(f"essay coverage: {pct}% ({len(covered)}/{len(features)} features)")
    missing = [f for f in features if f not in covered]
    for fid in missing:
        print(f"  uncovered: {fid} — {features[fid]['title']}")
    for line in stale:
        print(f"  stale: {line}")
    for line in errors:
        print(f"  error: {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

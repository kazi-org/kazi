#!/usr/bin/env python3
"""T31.3 / ADR-0036 Layer 2 — gated knowledge extraction (propose-then-confirm).

Runs AFTER Layer 1 (`trim_plan.py`) has archived a fully-done, released epic
verbatim under `docs/plans/archive/`. This pass lifts only the DURABLE nuggets
out of that archived block and routes each to the correct doc tier — exactly the
ADR-0036 tier map:

    invariant / landmine -> docs/lore.md      (the highest bar: rules)
    finding   / benchmark -> docs/devlog.md   (where most findings land)
    decision              -> docs/adr/        (a NEW proposed ADR file)
    architecture          -> docs/concept.md  (canonical architecture; NOT design.md)

Two properties make this safe to be the only LLM-shaped step in the lifecycle:

  * NON-DESTRUCTIVE — the archive (`docs/plans/archive/*.md`) is NEVER written
    to or deleted from. It is the lossless backstop, so a routing mistake never
    LOSES knowledge: the nugget still lives, verbatim, in the archive.
  * GATED — dry-run by default. It PROPOSES tier-routed edits (prints the routing
    + the house-format entry per tier) for human review. `--apply` is the
    human-confirm gate; nothing is written without it (cf. ADR-0036 Layer 2).

Nuggets are found three ways, highest confidence first:
  1. Explicit annotation:  `Nugget(invariant): <text>`  or  `Nugget: invariant -- <text>`
  2. Class hashtag:        a line carrying `#invariant`/`#landmine`/`#finding`/
                           `#benchmark`/`#decision`/`#architecture`
  3. Keyword heuristic:    prose lines that read like an invariant/benchmark/etc.
Each routed edit embeds a `kx:<sig>` provenance marker so re-running is idempotent.

Usage:
  extract_knowledge.py --epic docs/plans/archive/E1.md   # dry-run: propose routing
  extract_knowledge.py --latest                          # newest-archived epic
  extract_knowledge.py --epic <file> --apply             # write the proposed edits
  extract_knowledge.py --latest --root <repo>            # repo root (default: cwd)
"""
import argparse
import hashlib
import re
import sys
from datetime import date
from pathlib import Path

# --- ADR-0036 tier map (the contract these tests pin) ------------------------
CLASS_TIER = {
    "invariant": "lore",
    "landmine": "lore",
    "finding": "devlog",
    "benchmark": "devlog",
    "decision": "adr",
    "architecture": "concept",
}
TIER_FILE = {
    "lore": "docs/lore.md",
    "devlog": "docs/devlog.md",
    "adr": "docs/adr/",          # a directory: each decision is a NEW file
    "concept": "docs/concept.md",
}
CLASSES = tuple(CLASS_TIER)

# --- nugget detection --------------------------------------------------------
# 1. explicit annotation
ANNOT_RE = re.compile(
    r"Nugget\s*(?:\((?P<c1>\w+)\)|:\s*(?P<c2>\w+))\s*(?:--|—|:)?\s*(?P<body>.+)",
    re.IGNORECASE,
)
# 2. class hashtag
TAG_RE = re.compile(r"#(" + "|".join(CLASSES) + r")\b", re.IGNORECASE)
# 3. keyword heuristic (ordered: first class whose pattern matches wins)
HEURISTIC = [
    ("landmine", re.compile(r"\b(landmine|footgun|gotcha|silently|never\s+\w+|must\s+never)\b", re.I)),
    ("invariant", re.compile(r"\b(invariant|must\s+always|always\s+holds?|guarantee[ds]?)\b", re.I)),
    ("benchmark", re.compile(r"\b(benchmark|measured|tokens?|latency|throughput|[0-9]+\s*[x×]\s|p9[0-9])\b", re.I)),
    ("decision", re.compile(r"\b(decided|decision|we\s+chose|adopt(?:ed)?|rejected|supersed)\b", re.I)),
    ("architecture", re.compile(r"\b(architecture|subsystem|data\s+model|the\s+\w+\s+layer|component\s+boundary)\b", re.I)),
    ("finding", re.compile(r"\b(finding|discovered|observed|turns\s+out|root\s+cause)\b", re.I)),
]
# lines we never treat as nuggets on their own (pure plan bookkeeping)
SKIP_RE = re.compile(r"^\s*(- \[[ x~]\] [TS][0-9]|#{1,3}\s|\*\*Component)")


def signature(epic_name: str, text: str) -> str:
    return hashlib.sha1(f"{epic_name}::{text}".encode()).hexdigest()[:10]


def classify_line(line: str):
    """Return (class, confidence) for a knowledge line, or None."""
    m = ANNOT_RE.search(line)
    if m:
        cls = (m.group("c1") or m.group("c2") or "").lower()
        if cls in CLASS_TIER:
            return cls, m.group("body").strip(), "explicit"
    m = TAG_RE.search(line)
    if m:
        cls = m.group(1).lower()
        body = TAG_RE.sub("", line).strip(" -—\t")
        return cls, body, "tagged"
    if SKIP_RE.match(line):
        return None
    stripped = line.strip()
    if len(stripped) < 25:  # too short to be a durable nugget
        return None
    for cls, pat in HEURISTIC:
        if pat.search(stripped):
            return cls, re.sub(r"^[-*>\s]+", "", stripped), "inferred"
    return None


def extract_nuggets(epic_name: str, body: str):
    """Yield dicts: {class, tier, confidence, text, title, sig} for one epic."""
    nuggets = []
    for raw in body.splitlines():
        hit = classify_line(raw)
        if not hit:
            continue
        cls, text, conf = hit
        text = text.strip()
        if not text:
            continue
        title = re.split(r"(?<=[.;])\s", text, 1)[0].rstrip(".;").strip()
        if len(title) > 90:
            title = title[:87].rstrip() + "..."
        nuggets.append({
            "class": cls,
            "tier": CLASS_TIER[cls],
            "confidence": conf,
            "text": text,
            "title": title,
            "sig": signature(epic_name, text),
        })
    return nuggets


# --- source selection --------------------------------------------------------
def latest_archived_epic(root: Path) -> Path | None:
    """The most-recently-archived epic: last entry in the master's `## Archived
    epics` section, else newest file by mtime under docs/plans/archive/."""
    plan = root / "docs" / "plan.md"
    if plan.exists():
        in_section, last = False, None
        for line in plan.read_text().splitlines():
            if line.strip() == "## Archived epics":
                in_section = True
                continue
            if in_section and line.startswith("## "):
                break
            if in_section:
                m = re.search(r"plans/archive/(\S+\.md)", line)
                if m:
                    last = m.group(1)
        if last:
            cand = root / "docs" / "plans" / "archive" / last
            if cand.exists():
                return cand
    arch = root / "docs" / "plans" / "archive"
    files = sorted(arch.glob("*.md"), key=lambda p: p.stat().st_mtime) if arch.is_dir() else []
    return files[-1] if files else None


# --- house-format rendering per tier -----------------------------------------
def next_lore_id(text: str) -> str:
    ids = [int(m) for m in re.findall(r"L-(\d{4})", text)]
    return f"L-{(max(ids) + 1 if ids else 1):04d}"


def next_adr_number(adr_dir: Path) -> int:
    nums = [int(m.group(1)) for p in (adr_dir.glob("*.md") if adr_dir.is_dir() else [])
            if (m := re.match(r"(\d{4})-", p.name))]
    return (max(nums) + 1) if nums else 1


def slugify(title: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return "-".join(s.split("-")[:8]) or "extracted-decision"


def render_lore(n, lore_text, src) -> str:
    lid = next_lore_id(lore_text)
    tag = "landmine" if n["class"] == "landmine" else "invariant"
    return (f"\n### {lid} #extracted #{tag} -- {n['title']} <!-- kx:{n['sig']} -->\n"
            f"{n['text']}\n(extracted from {src}, T31.3.)\n")


def render_devlog(n, src) -> str:
    today = date.today().isoformat()
    kind = "benchmark" if n["class"] == "benchmark" else "finding"
    return (f"## {today} — {n['title']} (extracted {kind}) <!-- kx:{n['sig']} -->\n\n"
            f"{n['text']}\n\nExtracted from {src} during plan archival (T31.3).\n\n")


def render_concept(n, src) -> str:
    return (f"\n### {n['title']} (extracted architecture) <!-- kx:{n['sig']} -->\n\n"
            f"{n['text']}\n\n_Extracted from {src} (T31.3); fold into the narrative above._\n")


def render_adr(n, number, src) -> str:
    return (f"# ADR {number:04d}: {n['title']}\n\n"
            f"## Status\nProposed <!-- kx:{n['sig']} -->\n\n"
            f"## Date\n{date.today().isoformat()}\n\n"
            f"## Context\n\nExtracted from the archived plan block {src} (T31.3 /"
            f" ADR-0036 Layer 2). The archive holds the original, verbatim.\n\n"
            f"## Decision\n\n{n['text']}\n\n"
            f"## Consequences\n\n_To be completed on human review._\n")


def already_present(root: Path, n) -> bool:
    """Idempotency: the kx provenance marker already lives in any target tier."""
    marker = f"kx:{n['sig']}"
    if n["tier"] == "adr":
        adr_dir = root / "docs" / "adr"
        return any(marker in p.read_text() for p in adr_dir.glob("*.md")) if adr_dir.is_dir() else False
    f = root / TIER_FILE[n["tier"]]
    return f.exists() and marker in f.read_text()


# --- propose + apply ---------------------------------------------------------
def apply_nugget(root: Path, n, src) -> str:
    """Write one routed edit in its tier's house format. Returns the dest label."""
    if n["tier"] == "lore":
        f = root / TIER_FILE["lore"]
        f.write_text(f.read_text().rstrip("\n") + "\n" + render_lore(n, f.read_text(), src))
        return TIER_FILE["lore"]
    if n["tier"] == "devlog":
        f = root / TIER_FILE["devlog"]
        lines = f.read_text().splitlines(keepends=True)
        # newest-first: insert below the header block (first blank line after H1)
        insert = next((i for i, l in enumerate(lines) if i > 0 and l.startswith("## ")), len(lines))
        lines[insert:insert] = [render_devlog(n, src) + "\n"]
        f.write_text("".join(lines))
        return TIER_FILE["devlog"]
    if n["tier"] == "concept":
        f = root / TIER_FILE["concept"]
        f.write_text(f.read_text().rstrip("\n") + "\n" + render_concept(n, src))
        return TIER_FILE["concept"]
    if n["tier"] == "adr":
        adr_dir = root / "docs" / "adr"
        adr_dir.mkdir(parents=True, exist_ok=True)
        number = next_adr_number(adr_dir)
        dest = adr_dir / f"{number:04d}-{slugify(n['title'])}.md"
        dest.write_text(render_adr(n, number, src))
        return str(dest.relative_to(root))
    raise AssertionError(f"unknown tier {n['tier']}")


def main():
    ap = argparse.ArgumentParser(description="Gated knowledge extraction (ADR-0036 Layer 2).")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--epic", help="archived epic file to extract from")
    g.add_argument("--latest", action="store_true", help="use the most-recently-archived epic")
    ap.add_argument("--apply", action="store_true", help="write the proposed edits (human-confirm gate)")
    ap.add_argument("--root", default=".", help="repo root (default: cwd)")
    args = ap.parse_args()
    root = Path(args.root).resolve()

    if args.epic:
        epic = Path(args.epic)
        epic = epic if epic.is_absolute() else root / epic
    elif args.latest:
        epic = latest_archived_epic(root)
        if not epic:
            sys.exit("ERROR: no archived epic found under docs/plans/archive/.")
    else:
        sys.exit("ERROR: pass --epic <archived file> or --latest.")
    if not epic.exists():
        sys.exit(f"ERROR: {epic} does not exist.")

    src = epic.name
    nuggets = extract_nuggets(src, epic.read_text())
    if not nuggets:
        print(f"No durable nuggets found in {src}. (The archive is unchanged.)")
        return

    pending = [n for n in nuggets if not already_present(root, n)]
    skipped = len(nuggets) - len(pending)

    print(f"Knowledge extraction — source: docs/plans/archive/{src}")
    print(f"  archive is the lossless backstop; it is NEVER modified or removed from.\n")
    by_tier = {}
    for n in pending:
        by_tier.setdefault(n["tier"], []).append(n)
    for tier in ("lore", "devlog", "adr", "concept"):
        for n in by_tier.get(tier, []):
            print(f"  [{TIER_FILE[tier]}]  {n['class']} ({n['confidence']})")
            print(f"      {n['title']}")
    print(f"\n{len(pending)} nugget(s) -> {len(pending)} routed edit(s); "
          f"{skipped} already present (idempotent).")

    if not args.apply:
        print("\ndry-run; review the routing above, then pass --apply to write.")
        return

    for tier in ("lore", "devlog", "adr", "concept"):
        for n in by_tier.get(tier, []):
            dest = apply_nugget(root, n, src)
            print(f"wrote {n['class']} -> {dest}")
    print(f"\nApplied {len(pending)} routed edit(s). docs/plans/archive/{src} left untouched.")


if __name__ == "__main__":
    main()

# Essays — the feature-anchored deep dives

This directory is kazi's **essays** tier: one evergreen essay per *significant
shipped feature*, each explaining the problem the feature exists to solve, the
design decision behind it (anchored to its ADRs), and what it looks like in a
real run. Essays are a **marketing surface written to the engineering bar**: the
same no-hype, no-vaporware rules as the blog (`docs/blog-style.md`, ADR-0048)
apply verbatim.

## How essays differ from the blog

| Tier | Question it answers | Lifecycle |
| --- | --- | --- |
| Blog (`site/src/content/blog/`) | "How do I climb from vibe coding to reconciliation?" — a narrative ladder + field notes | Published once, timestamped, never rewritten |
| **Essays (`docs/essays/`)** | "Why does this *feature* exist, and how does it behave?" — one per significant feature | **Living**: updated whenever the feature changes, staleness machine-checked |
| ADRs (`docs/adr/`) | "What was decided and why?" | Frozen; superseded, never edited |

An essay is the *readable* companion to one or more frozen ADRs. The ADR is for
contributors; the essay is for a developer deciding whether kazi is worth an
hour of their time. Essays syndicate well (dev.to / newsletters) because each
one stands alone; when cross-posted, follow the canonical-URL syndication rule
in `docs/blog-series-announcement.md`.

## The living-document mechanism

Essays claim coverage of features via frontmatter, and a deterministic checker
holds the section honest — the same pattern as the doc-lifecycle standing goal
(ADR-0036): all logic in a script, kazi only *drives* it.

- **`features.toml`** — the curated manifest of significant shipped features.
  Each entry names the feature and its *anchors* (the ADR/doc files that define
  it). Adding a significant feature to kazi means adding a row here (the same
  "docs land with the code" discipline as ADR-0034).
- **Essay frontmatter** — every essay declares `covers: [<feature-id>, ...]`
  and `reviewed: YYYY-MM-DD` (the date a human last verified the essay against
  the shipped behavior).
- **`check_essay_coverage.py`** — the checker:
  - `--check` exits non-zero if any essay covers an unknown feature id, or any
    essay is **stale** (an anchor file has a git commit newer than the essay's
    `reviewed:` date);
  - `--metric coverage` prints the bare % of manifest features covered by at
    least one essay (a `ratchet`, `higher_better`);
  - `--metric stale` prints the bare count of stale essays (a `ratchet` to 0,
    `lower_better`);
  - no flags prints the human-readable report (coverage, missing features,
    stale essays).

Three ways to keep it alive, strongest first:

1. **The standing goal (primary, and the point).** `essays.goal.toml` in this
   directory wraps the checker in `custom_script` + `ratchet` predicates, with
   the checker and manifest `read_only_paths` to the agent (ADR-0042) so a fix
   arc must update the *essays*, never the grader:

   ```sh
   kazi apply docs/essays/essays.goal.toml --workspace .
   ```

   When a feature ships or changes, the coverage/staleness predicates go red
   and kazi dispatches an agent to write or refresh the essay — a human then
   reviews and bumps `reviewed:`. kazi keeping its own marketing content honest
   *is* the marketing story.
2. **CI (optional).** Add `python3 docs/essays/check_essay_coverage.py --check`
   to the doc-freshness job to make staleness a PR-blocking predicate.
3. **A Claude Code hook (lightweight alternative).** A `Stop` hook that surfaces
   drift at the end of any session that touched anchored files:

   ```json
   {
     "hooks": {
       "Stop": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "python3 docs/essays/check_essay_coverage.py --check || echo 'essays drifted: run python3 docs/essays/check_essay_coverage.py'"
             }
           ]
         }
       ]
     }
   }
   ```

## Writing an essay

Copy `TEMPLATE.md`. Rules of the road (inherited from `docs/blog-style.md`):

- Lead with the reader's pain, not the feature name.
- Only shipped behavior; every command verified against `kazi help --json`.
- No number stated as measured unless it is reproducible (link the
  `docs/dogfood-methodology.md` entry).
- Name the anchoring ADRs at the end, not the top.
- 600–1200 words. One idea per essay. If it needs two ideas, it is two essays.

## The backlog

Coverage state is computed, not hand-maintained — run the checker for the live
report:

```sh
python3 docs/essays/check_essay_coverage.py
```

The manifest (`features.toml`) is the single source of truth for which features
deserve an essay. Seeded with the features below; the checker reports which are
still uncovered:

| Feature id | The essay's hook (working title) |
| --- | --- |
| `objective-done` | "Done" is not the agent's opinion |
| `guard-predicates` | The agent that deleted the failing test |
| `budgets` | The loop that cannot run forever |
| `live-predicates` | Green on your laptop is not deployed |
| `ratchet-predicate` | Ratchets: metrics that only move one way |
| `blast-radius-leases` | Two agents, one file: leases beat locks |
| `predicate-graph-waves` | Waves: parallelism you can prove safe |
| `token-economy` | Frontier judgment once, cheap iterations forever |
| `harness-agnostic` | kazi gets better every time your agent does |
| `self-teaching` | The CLI that teaches itself to your agent |
| `self-maintaining-docs` | The docs that fix themselves |
| `scenario-predicates` | From Gherkin prose to replayable truth |

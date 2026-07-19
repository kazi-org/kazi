# ADR 0062: Semantic memory -- git-native store, FTS recall under a token budget

## Status

Accepted

## Date

2026-07-07

## Refines

ADR-0060 (layer 3; guardrail 1 "librarian, never vault" is THIS layer's law),
ADR-0012 (the pluggable retrieval seam gets its first functional default
backend), ADR-0045 (retires the external-provider ambition; context_store
becomes an internal seam), ADR-0010/0047 (recall is an orientation lever,
tier-gated), ADR-0052 (the store must be generic project files, never an
operator-personal convention).

## Context

Project knowledge -- invariants, landmines, conventions, decisions -- is what
keeps a cheap model from re-stepping on known rakes. kazi has had three
non-functional passes at this layer: the ADR-0012 retrieval adapter whose only
backend was retired as never-functional (ADR-0052), the ADR-0045 context_store
whose Gist provider never engages in practice (its 4000-byte provider evidence
cap sits under the 5120-byte store threshold -- a seam mismatch nothing
detected), and the de-facto reality that the knowledge itself lives wherever a
given operator keeps it. Three failures, one shared shape: the mechanism was
built around an EXTERNAL store or process, so nothing in kazi's test suite
could prove the path worked end-to-end.

Meanwhile every project kazi drives already has a semantic store: markdown in
git. ADRs, a lore/landmines file, a devlog, `AGENTS.md`, `README`. It is
human-reviewed, versioned, diffable, and survives every tool. What is missing
is not a store -- it is a librarian: something that can answer "what does this
project already know that bears on THIS failing predicate?" inside a strict
token budget, at dispatch-assembly time.

## Decision

1. **The store of record is repo markdown; kazi never copies it into an
   opaque database.** Default corpus: `docs/adr/**/*.md`, `docs/lore.md`,
   `docs/devlog.md`, `AGENTS.md`, `CLAUDE.md`, `README.md` -- overridable per
   goal-file via a `[memory]` block (`corpus = [...]` globs). Files remain the
   truth; deleting kazi's index loses nothing but a rebuild.

2. **Index: SQLite FTS5 in the existing read-model.** Chunked at
   heading/entry granularity with source path + line span, incrementally
   refreshed by content hash (the read-model already carries snippet/pack
   caches; this generalizes them). FTS5 ships inside the SQLite already in
   the stack: zero new dependencies. Embeddings/vector search are explicitly
   out until a benchmark shows FTS ranking is the binding constraint, and
   adopting them requires a superseding ADR (stack-conventions rule: no heavy
   deps without an ADR).

3. **The API is budgeted recall, not search.** One function with one
   contract: query terms in, a ranked slice out that is GUARANTEED to fit the
   caller's token budget, each snippet carrying its source (`path:line`).
   Surfaced three ways, all the same function: the loop at context-assembly
   time; `kazi memory recall <query> --budget <n> [--json]` for operators and
   orchestrating agents; and `kazi mcp` (ADR-0044) for interactive sessions --
   which is what makes a sibling memory tool unnecessary for reuse (ADR-0060).

4. **Loop integration is tier-gated and query-derived.** The recall query is
   derived from the failing predicates (ids, error fingerprints, touched
   paths) -- deterministic, never model-authored. Which tiers include recall,
   and at what budget, is an ADR-0047 context-tier parameter; like the
   attempt ledger it ships behind a flag and must pay rent under the
   ADR-0046 envelope before defaulting on (ADR-0060 guardrail 4).

5. **Recall is read-only.** This ADR adds no write path to the corpus. All
   writes to semantic memory -- harvest, promotion, decay -- are ADR-0063's
   gated pipeline. During a run, corpus files are eligible `read_only_paths`
   (ADR-0042) so the inner agent cannot edit the project's beliefs to make
   recall agree with its work.

6. **ADR-0012's seam survives; ADR-0045's external ambition does not.** The
   FTS backend is the default implementation behind the existing retrieval
   seam, so a future backend (including embeddings, post-benchmark) is a
   config change. The context_store behaviour remains internal plumbing; the
   Gist provider is legacy, and its threshold mismatch is thereby mooted
   rather than patched.

## Consequences

- First-run indexing cost is a one-time scan of a handful of markdown files;
  incremental refresh rides content hashes. Index size is trivial next to
  the existing read-model.
- Projects with no lore/devlog get exactly the current behavior (empty
  corpus, zero recall, zero cost) -- adoption is progressive and per-repo.
- The corpus definition creates gentle pressure toward the conventional file
  layout (`docs/lore.md`, `docs/adr/`) without mandating it -- the `[memory]`
  block keeps any layout reachable, honoring ADR-0052.
- End-to-end testability returns: corpus fixture + index + recall + injection
  is one ExUnit path with no network, no external process -- the property
  every prior attempt at this layer lacked.
- Recall quality is bounded by corpus quality; that is by design. The fix for
  a thin corpus is ADR-0063's harvest, not a cleverer ranker.

## Alternatives rejected

- **Fix the Gist provider thresholds and keep the external store.** Repairs
  one mismatch while keeping the seam class that produced it (plus a network
  dependency and an un-reviewable store) on the dispatch path. The failure
  was structural, not a constant.
- **Embeddings-first retrieval.** A heavy dependency and an inference cost
  per dispatch, adopted to beat a baseline (FTS over a curated, small,
  heading-structured corpus) that has not been shown to lose. Measure first;
  supersede if beaten.
- **Index the whole repo, not a curated corpus.** Turns recall into code
  search -- the inner harness already greps code better than an index can,
  and diluting the corpus with code buries the high-signal beliefs the layer
  exists to surface. The graph/code tools remain the code-navigation story.
- **A memory database with its own document format.** Violates guardrail 1:
  beliefs the operator cannot `cat`, diff, or review in a PR are beliefs that
  rot invisibly. Git IS the review pipeline for knowledge.

# Memory

Memory is kazi-core: the controller's own state, at four timescales, not a
feature bolted alongside the loop (ADR-0060). It is a fourth READ of the same
stores [concept.md §9](concept.md#9-architecture--data-layers-adr-0003-adr-0004-adr-0005)
already describes — no fifth store, no new dependency.

| Layer | Timescale | Content | Mechanism (owning ADR) |
|---|---|---|---|
| Working | this iteration | failing predicates, evidence, orientation | evidence projection + orientation pack (0009/0010/0047) |
| Episodic | this goal | what was tried, what changed, what didn't | attempt ledger (0061, this doc) |
| Semantic | this project | invariants, landmines, conventions | git-native recall (0062) |
| Statistical | cross-project | cost/outcome by goal shape and model | economy envelope + learned budgets (0046/0058) |

In control terms: working memory is the proportional input, episodic is the
integral term, statistical is gain scheduling, semantic is the plant model. A
reconciler without the integral term repeats its own failed corrections.

Two guardrails hold across every layer (ADR-0060):

- **Librarian, never vault.** Durable memory (the semantic layer) is
  git-versioned markdown in the workspace repo — `cat`-able, reviewable,
  survives kazi vanishing. Episodic and statistical state are run FACTS, not
  knowledge, and live in the read-model like every other run fact.
- **Gated writes.** Anything expressing a BELIEF about the project reaches the
  semantic layer only through propose-then-confirm (ADR-0063). The inner agent
  never writes memory directly.

## Episodic memory: the attempt ledger (ADR-0061)

`Kazi.Memory.AttemptLedger` (`lib/kazi/memory/attempt_ledger.ex`) is a
**deterministic fold**, never a document an agent authors, over the read-model
facts the loop already records for one goal: the per-iteration predicate
vector history and the dispatch log (which failing predicates each dispatch
targeted, seeded with what evidence). Nothing in it comes from model or
transcript prose — the same confabulation stance ADR-0058 takes for debrief
hypotheses.

For each recorded dispatch attempt the fold derives:

- the failing-predicate set it targeted;
- the touched-file set (when the caller has one to report);
- an error fingerprint — a short deterministic hash of `(failing set, touched
  set, normalized error head)` (decision 3: crude on purpose, no semantic
  similarity, no model in the loop);
- its observable effect — whether the SAME failing set persisted to the next
  recorded observation (`:no_change`), changed/shrank (`:changed`), or has no
  later observation yet (`:unknown`).

Attempts sharing a fingerprint fold into one ledger entry, carrying every
iteration it recurred at. That is the substrate for the headline line the
rendered section affords when true: *"approach F was tried at iterations N, M
and did not change predicate P's verdict — do not repeat it."*

`Kazi.Loop.StuckDetector` reads the SAME failing-set fold
(`AttemptLedger.failing_sets/1`) for its stuck/no-progress window, so
controller policy and the ledger rendered into the prompt can never disagree
about what the history says (decision 4).

### Prompt injection

When enabled, the loop (`Kazi.Loop`) appends a bounded `ATTEMPT LEDGER`
section to the dispatch prompt, after the evidence/context-store sections and
before retrieval — the volatile part of the prompt, never the stable
orientation prefix (T19.1/ADR-0010 §4 is unaffected). The section is
hard-capped to an approximate token budget (default ~800 tokens) and sorted
most-recent, most-repeated entries first; oversized ledgers are truncated from
the tail.

### Default OFF — the flag

The ledger ships behind a flag (ADR-0061 decision 6, ADR-0060 guardrail 4):

```elixir
# config/config.exs
config :kazi, :attempt_ledger, false
```

With the **default `false`**, `Kazi.Loop` renders no `ATTEMPT LEDGER`
section at all — the dispatch prompt is byte-identical to before the ledger
existed. Override per-run via the loop's `:adapter_opts`:

```elixir
Kazi.Loop.start_link(goal: goal, adapter_opts: [attempt_ledger: true], ...)
```

On the **released binary** (where compile-time config is baked in and
`:adapter_opts` is not reachable from the CLI), enable it per process with an
environment variable — this is how the ADR-0046 pays-rent benchmark runs
against real goals on the shipped artifact:

```sh
KAZI_ATTEMPT_LEDGER=1 kazi apply <goal> --workspace <dir> ...
```

(`KAZI_MEMORY_RECALL=1` is the same hook for semantic recall, below. `1` or
`true` enables; unset/anything else keeps the compiled default.)

Promotion to default-on requires the ADR-0046 benchmark to show a measured
win (iterations-to-converge, stuck rate, cost-to-converge, with vs. without,
fixed model + budget) — a null result means removal, not tuning forever.

### Cross-run inclusion

The fold has no notion of a run boundary: it keys on whatever history the
caller hands it. Querying the read-model by GOAL identity (not run id) and
folding the concatenated history means a resumed goal starts with its full
prior-run history instead of amnesia — free, by construction.

## Semantic memory: git-native recall (ADR-0062)

`Kazi.Memory.SemanticIndex` (`lib/kazi/memory/semantic_index.ex`) answers "what
does this project already know that bears on THIS failing predicate?" inside a
strict token budget, at dispatch-assembly time.

### The store of record is repo markdown

kazi never copies project knowledge into an opaque database — the corpus IS
the truth (the "librarian, never vault" guardrail above). The default corpus:

```
docs/adr/**/*.md
docs/lore.md
docs/devlog.md
AGENTS.md
CLAUDE.md
README.md
```

A goal overrides the set entirely via its `[memory]` table:

```toml
[memory]
corpus = ["docs/**/*.md", "AGENTS.md"]
```

Absent, or present with no `corpus` key, the default corpus applies. An
explicit `corpus = []` opts the goal OUT of recall entirely — zero recall, zero
cost, valid for any project (one with no lore/devlog gets exactly today's
behavior since its globs simply match no file).

### Index: SQLite FTS5, zero new dependencies

Corpus files are chunked at heading/entry granularity — each chunk keeps its
source `path` + line span — and indexed into a `memory_chunks_fts` FTS5
virtual table living in the SAME SQLite read-model every other projection
uses. FTS5 ships inside the `ecto_sqlite3`/`exqlite` stack already, so this
adds no new dependency. A refresh re-chunks a file only when its sha256
content hash has changed since it was last indexed (tracked in
`Kazi.ReadModel.MemoryIndexFile`) — an unchanged file is never re-indexed.
Embeddings/vector search are explicitly out until a benchmark shows FTS
ranking is the binding constraint (a superseding ADR would be required to add
one, per the stack-conventions no-heavy-deps rule).

### The API is budgeted recall, not search

```elixir
Kazi.Memory.SemanticIndex.recall("budget overflow", 200, workspace: ".")
# => [%{path: "docs/lore.md", line: 3, text: "...", score: 1.87}, ...]
```

One function, one contract: query terms in, a ranked slice out GUARANTEED to
fit the caller's token budget (an approximate 4-chars-per-token heuristic,
like the attempt ledger's rendering cap above). The top-ranked chunk alone
exceeding the budget is truncated — never dropped-with-overflow.

Surfaced three ways, all the same function:

- the loop, at dispatch-assembly time (below);
- `kazi memory recall <query> --budget <tokens> [--json]` for operators and
  orchestrating agents;
- `kazi mcp` (ADR-0044), for an interactive session.

### Prompt injection — default OFF

When enabled, `Kazi.Loop` appends a `## Recalled project knowledge` section
after the attempt ledger and before retrieval. The recall query is derived
DETERMINISTICALLY from the dispatch's failing-predicate ids and the
working-set digest's touched paths — never model-authored (the same
facts-only discipline the attempt ledger follows).

```elixir
# config/config.exs
config :kazi, :memory_recall, false
```

With the **default `false`**, the dispatch prompt carries no recalled-knowledge
section at all — byte-identical to before this layer existed. Override
per-run via the loop's `:adapter_opts` (`memory_recall: true`,
`memory_recall_max_tokens: <n>`, default 1500), or on the released binary via
the per-process environment hook `KAZI_MEMORY_RECALL=1` (see the attempt
ledger's flag section — same mechanism, same benchmark discipline). Promotion
to default-on requires the same ADR-0046 benchmark discipline as the attempt
ledger.

### Recall is read-only

`SemanticIndex` adds no write path to the corpus — it only ever reads corpus
files; every write targets the SQLite index, never the source markdown.
Corpus files are eligible `[enforcement] read_only_paths` (ADR-0042), so a
goal can lease its corpus read-only during a run and the inner agent cannot
edit the project's beliefs to make recall agree with its work.

## Gated harvest and promotion (ADR-0063)

Recall (ADR-0062) only ever *reads* the corpus; nothing before this layer
*grows* it except a human remembering to write. `Kazi.Memory.Harvest` closes
that gap at run termination without opening a write path an inner agent could
ever reach — a wrong belief injected straight into the corpus is worse than
none, since it would be recalled into every future relevant dispatch.

### Harvest: deterministic detection, into PROPOSALS only

`Kazi.Memory.Harvest.harvest/3` runs controller-side, from `Kazi.Runtime.run/2`
right after the loop reaches a terminal state (converged / stopped /
over_budget) — never from `Kazi.Harness` or an action module, so the
dispatched agent has no path to influence what gets proposed. On a
non-`:converged` outcome it reads the goal's own persisted iteration log
(`Kazi.ReadModel.list_iterations/1`, the same episodic facts the attempt
ledger folds) and looks for a dispatch APPROACH — the same `(failing
predicates, touched files, normalized error head)` fingerprint
`Kazi.Memory.AttemptLedger.fingerprint/3` already defines — repeated three or
more times with no change to the failing set. That is the ADR's own example:
"a predicate that wedged three different goals the same way is a landmine."

No model runs in the detector; every candidate's `content` is a template
filled from facts already on record (the same confabulation stance ADR-0058
takes for debrief hypotheses). A candidate is stored as a row in
`Kazi.ReadModel.ProposedMemory` (the `proposed_memories` table, mirroring
`proposed_goals`) via `Kazi.ReadModel.propose_memory/1`, keyed idempotently by
the detector's fingerprint — harvesting the same facts twice (a resumed goal,
a re-run over the same history) never inserts a duplicate, whether the
existing row is still `proposed` or has already been `rejected`.

### Promotion: a human-approved diff, never a kazi commit

`kazi memory list-proposed [--status <state>] [--json]` is the review queue.
`kazi memory approve <proposal-ref> [--json]` transitions a proposal to
`approved` AND writes its content into the routed corpus file:

| class | target |
|---|---|
| `invariant` / `landmine` | `docs/lore.md` |
| `finding` / `benchmark` | `docs/devlog.md` |
| `decision` | a drafted `docs/adr/NNNN-*.md` stub |

`Kazi.Memory.Promote` does the writing — an ORDINARY working-tree edit the
operator reviews and lands like any other doc change (ADR-0034). kazi never
commits memory on its own authority. Every written entry carries a
`<!-- kx:<fingerprint> -->` trailer (the same provenance-marker convention
`.github/scripts/extract_knowledge.py` uses for archived-plan knowledge), so
promoting an already-promoted proposal is a no-op rather than a duplicate
entry. `kazi memory reject <proposal-ref> [--json]` declines a proposal
(kept for audit) without touching any corpus file — its fingerprint is never
re-proposed.

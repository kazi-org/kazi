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

Promotion to default-on requires the ADR-0046 benchmark to show a measured
win (iterations-to-converge, stuck rate, cost-to-converge, with vs. without,
fixed model + budget) — a null result means removal, not tuning forever.

### Cross-run inclusion

The fold has no notion of a run boundary: it keys on whatever history the
caller hands it. Querying the read-model by GOAL identity (not run id) and
folding the concatenated history means a resumed goal starts with its full
prior-run history instead of amnesia — free, by construction.

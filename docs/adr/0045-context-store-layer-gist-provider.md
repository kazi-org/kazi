# ADR 0045: A context-store layer (text-artifact memory), with Gist as the first provider

## Status
Proposed

## Date
2026-06-24

## Relates to
ADR-0010 (context injection to mitigate re-exploration) and ADR-0012 (pluggable
semantic-retrieval memory adapter). This ADR adds a layer those two do not cover:
not the structural orientation pack (0010), not embedding recall (0012), but
**budget-fitted retrieval over heavy text artifacts and repeated loop evidence**.
ADR-0008 (kazi owns context) is the authority for what enters a harness turn; this
ADR is one more thing kazi can put there, under an explicit byte budget.

## Context

kazi's per-iteration context has two well-modelled shapes: a stable structural
**orientation pack** (where things are — code-review-graph / repo-map, ADR-0010) and
optional **semantic retrieval** (embedding recall, ADR-0012, off by default). Neither
addresses the cost that actually grows a reconcile loop: **heavy, repeated text
artifacts**.

A single failing run can carry kilobytes of test logs, compiler diagnostics,
dependency-resolution output, harness stderr, prior-iteration summaries, and verbose
`git diff`. Today these either bloat the prompt (paid every iteration) or get
truncated blind (`truncate_evidence/2`'s head+tail window, T19.3 — which caps size
but cannot rank). When the loop goes `stuck` and escalates Haiku→Sonnet→Opus
(ADR-0035), the higher, pricier rung re-pays for the entire lower rung's raw
transcript.

`sirerun/gist` (Apache-2.0, a sibling OSS project) is built for exactly this: a Go
context-intelligence lib + CLI + MCP server that chunks content (Markdown/JSON/YAML/
text, heading- and code-block-aware), indexes it once, and returns **only
budget-fitting, ranked snippets** via three-tier lexical search (Porter stemming,
trigram, fuzzy). It is **lexical, not structural** — it has no call graph, AST, or
type model — so it is a complement to code-review-graph, never a replacement. Its
project-local E2E benchmark indexes a 754 KB OpenAPI spec and returns ~7.5 KB for
targeted search (~98.9% byte reduction); treat that as directional, not a guarantee.

There is a real risk of a confusing "double retrieval stack" if Gist is bolted on
without naming the layers. The layering this ADR fixes:

| Need | Layer | Provider |
|---|---|---|
| symbol / call / test impact | structural orientation | code-review-graph / graphify (ADR-0010) |
| embedding recall of prior context | semantic retrieval | ADR-0012 adapters (off by default) |
| **heavy docs / logs / specs / transcripts under a token budget** | **context store (new)** | **Gist** |
| objective convergence | controller | kazi |

## Decision

1. **Introduce a `context_store` layer, distinct from `retrieval`.** A behaviour
   `Kazi.ContextStore` with `index/3`, `search/3`, and `stats/1`. It is named and
   configured separately from `retrieval.provider` (ADR-0012) and from
   `harness.profile`. The store owns *text-artifact memory*; retrieval owns *embedding
   recall*; the orientation pack owns *structure*. Three names, three jobs.

2. **Gist is the first provider, via a CLI adapter.** `Kazi.ContextStore.GistCLI`
   shells to `gist index` / `gist search --budget N` / `gist stats`, detected on
   `PATH`. In-memory by default; PostgreSQL when `KAZI_GIST_DSN` is set (long-running
   / multi-agent / CI). The CLI adapter keeps the integration language-agnostic and
   is enough for a useful MVP; a persistent sidecar or native protocol can come later
   behind the same behaviour.

3. **The store's primary job is evidence compression between iterations, not
   indexing source.** On each iteration, any artifact over a threshold (default
   5 KB) is indexed under a stable source label; the loop state keeps only the label,
   checksum, byte count, and a short machine summary — not the bytes. Before the next
   harness turn, kazi queries the store for the current failing predicate, changed
   files, and recent error signature, and injects only the returned snippets under a
   fixed budget. Context shifts from append-only transcript growth to
   retrieve-on-demand evidence.

4. **Stable, SHA-scoped source labels** so changed files invalidate cleanly:

   ```
   kazi:workspace:<git_sha>:docs:<path>
   kazi:goal:<goal_id>:predicate:<predicate_id>:rationale
   kazi:run:<goal_id>:iter:<n>:test-log
   kazi:run:<goal_id>:iter:<n>:harness-stderr
   kazi:run:<goal_id>:stuck:failure-cluster
   ```

5. **Stuck-bundle replay for escalation.** When `kazi apply` returns `stuck`, kazi
   assembles a compact bundle — failing predicates, last changed files, top store
   snippets for the error signatures, last test command + normalized failure, minimal
   diff summary — and the ADR-0035 escalation hands *that* to the higher rung instead
   of the lower rung's full transcript. This is where the dollars are.

6. **Additive JSON only; convergence semantics unchanged.** The result contract
   (ADR-0023) gains an optional `context_store` object; absent ⇒ today's shape. A
   minor `schema_version` bump, never a break.

   ```json
   { "context_store": { "provider": "gist", "indexed_bytes": 754257,
     "returned_bytes": 7500, "saved_bytes": 746757, "budget": 6000 } }
   ```

7. **Outer agents may index and search; inner harnesses search only by default.**
   kazi indexes authoritative artifacts. An inner harness, if it has MCP, may call
   `gist_search` but not arbitrary indexing unless the goal opts in — uncontrolled
   inner indexing turns the store noisy. The inner-prompt contract gains one rule:
   *"Use the provided snippets as evidence; if you need more, request a targeted
   source/query — do not ask for whole logs or whole docs."*

8. **Full surface (phased, all opt-in):**
   - `kazi apply <goal> --context-store gist --context-budget 6000 --json`
   - `kazi context index|search|stats --provider gist [--budget N] [--json]` — a thin
     wrapper so users learn one CLI, while Gist stays independently useful.
   - `kazi init --with-gist` — verify `gist doctor`, write `.kazi/context.toml`,
     create project-local MCP config if supported, recommend `KAZI_GIST_DSN`, and
     **not** mutate global agent config unless explicitly asked.

9. **Recommended default budgets** (tunable): predicate-planning docs 4 000;
   apply-iteration snippets 6 000; stuck-escalation bundle 12 000; final
   verification 8 000.

## Consequences

- The escalation ladder (ADR-0035) stops re-paying for lower-rung transcripts — the
  measurable payoff the economy work (ADR-0046) will report as `saved_bytes` and
  cost-per-converged-predicate.
- Users can say "use the repo docs and the last CI log" without loading all of it;
  kazi rehydrates only the evidence relevant to the current predicate.
- kazi gains a clean home for OSS dogfooding of a sibling project — kazi drives Gist,
  Gist makes kazi's context small and measurable.
- **Risk — lexical, not semantic.** Gist will not understand call graphs or types.
  Mitigation: keep code-review-graph/graphify as the structural layer; Gist is for
  text-heavy artifacts only (the table above is the boundary).
- **Risk — stale context.** Indexed source goes stale after edits. Mitigation: git
  SHA + mtime + content hash in the label; invalidate changed files each iteration.
- **Risk — secret leakage.** Logs/configs can hold credentials. Mitigation: kazi
  applies the **same** redaction it applies to harness prompts (ADR-0009) *before*
  indexing — non-negotiable; an un-redacted store is a credential store.
- **Risk — double retrieval stack / MCP tool sprawl.** Mitigation: the named-layer
  table is the contract; inner harnesses get search-only; `context_store.provider`
  and `retrieval.provider` are distinct config keys that never alias.
- **Risk — unproven ratio on real kazi runs.** The 98.9% number is Gist's own
  fixture. Mitigation: ship opt-in, report the real `indexed→returned` ratio per run
  (ADR-0046), and promote to a default only if the measured ratio holds.

## Alternatives rejected

- **Fold Gist under the existing `retrieval` adapter (ADR-0012).** Conflates two
  different jobs — embedding recall vs budget-fitted text retrieval — and reintroduces
  the "double retrieval stack" confusion. Distinct layers, distinct names.
- **Replace code-review-graph with Gist.** Category error: Gist is lexical. The
  structural layer is load-bearing for blast-radius partitioning (ADR-0006/0027) and
  must stay.
- **Build a kazi-native chunk/rank/budget engine.** Re-implements a maintained sibling
  OSS project for no gain; Gist already exists, is Apache-2.0, and has an MCP server.
- **Always-on, mandatory.** Premature: the byte-reduction ratio is unproven on kazi's
  own artifacts, and an always-on indexer adds latency and a secret-handling surface.
  Opt-in until measured (ADR-0046), then reconsider the default.
</content>

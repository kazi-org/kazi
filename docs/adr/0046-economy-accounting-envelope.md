# ADR 0046: Economy accounting envelope — cached-vs-fresh tokens, cost, and cost-per-converged-predicate

## Status
Accepted

## Date
2026-06-24

## Refines
ADR-0023 (the versioned `--json` result contract) and ADR-0041 (the predicate
envelope v2). ADR-0041 enriched the per-PREDICATE result with a graded score; this
ADR enriches the per-ITERATION result with a usage/economy envelope. ADR-0035
(skill-driven tiering) is the consumer: tiering decisions should be made on cost and
convergence economics, not raw token totals.

## Context

Harness profiles today usually collapse provider usage into a single `tokens`
integer (folded into `budget_spent.tokens`). That number hides the distinctions that
matter for token economy:

- **cached-read input** is priced far below fresh input on every major provider, yet
  it is budgeted as if it were fresh — so a stable-prefix cache hit (the whole point
  of T19.2) looks like a cost on the books instead of a saving;
- **cache-write**, **output**, and **reasoning** tokens have different prices and
  different controllability;
- **dollars** are what the operator actually optimizes, and they are not derivable
  from one token count across a multi-model ladder.

Without this split, the headline experiments (E19's multi-iteration benchmark
T19.5/T19.7; the ADR-0045 stuck-bundle savings) cannot be reported honestly: "total
tokens went up" is the *expected* effect of injecting a stable prefix, and the win
(cheaper cached reads + fewer rediscovery tool-calls) is invisible unless cached and
fresh tokens are counted separately. The right KPI is not tokens-per-run; it is
**cost per converged predicate**.

The providers already expose the fields, and kazi already parses them — then throws
them away. The `claude` profile's `total_tokens/1` (`lib/kazi/harness/profiles/claude.ex`)
reads `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, and
`cache_read_input_tokens` from the Claude envelope and **sums all four into one
`:tokens` integer**. The cache split is right there in the data and is discarded at
the moment of folding. This ADR is mostly about *not throwing that data away* and
giving it a stable schema home — the cheap-vs-fresh distinction the whole
token-economy program rests on is one un-summed map away.

## Decision

1. **Per-iteration `usage` envelope, additive to the JSON contract.** Preserve raw
   provider usage where available and surface a normalized shape:

   ```json
   { "usage": { "input_tokens": 0, "cached_input_tokens": 0, "cache_write_tokens": 0,
     "output_tokens": 0, "reasoning_tokens": 0, "cost_usd": 0.0 } }
   ```

   Fields are optional; a harness that cannot report a field omits it (no zero-as-
   unknown ambiguity — absent means unreported).

2. **Per-iteration `context` and `tools` counters** so context spend is attributable:

   ```json
   { "context": { "orientation_cache": "hit|miss|disabled",
     "retrieval_cache": "hit|miss|disabled", "orientation_tokens": 0,
     "evidence_tokens": 0, "retrieval_tokens": 0 },
     "tools": { "tool_calls": 0, "file_reads": 0, "search_calls": 0, "graph_calls": 0 } }
   ```

   These make the ADR-0010/0045 claims falsifiable: a working stable prefix shows
   rising `cached_input_tokens` and falling `file_reads`/`search_calls`.

3. **`budget_spent.tokens` stays for back-compat.** Existing orchestrators that pin
   the contract keep reading the same field; the envelope is strictly additive and
   bumps `schema_version` by a minor (never a v2.0.0 break — same rule as ADR-0041).

4. **Cached reads are not budgeted as fresh input.** The budget guard (ADR-0008's
   over-budget terminal) accounts `cached_input_tokens` at a configurable discount
   (default: treat as the provider's documented cache-read price ratio, or a flat
   low weight when price is unknown) so a cache-hit-heavy run is not falsely flagged
   `over_budget`. The *gate* is unchanged — only the cost arithmetic feeding it.

5. **kazi computes and records the economy KPIs** at run end, derived from the
   per-iteration envelopes:

   ```
   cost_usd per converged predicate
   wall-clock per converged predicate
   iterations to convergence
   fresh input tokens avoided (vs the no-cache baseline)
   rediscovery tool-calls avoided
   stuck rate by harness / model / context tier
   ```

6. **Honest-unknown discipline.** A harness profile that genuinely cannot produce a
   field (e.g. `claw`, best-effort) reports the envelope with that field absent and a
   `usage_fidelity: "partial|full|none"` marker, so a benchmark never silently treats
   a missing number as zero.

## Consequences

- The E19 benchmark verdict (T19.5/T19.7) and the ADR-0045 stuck-bundle savings
  become reportable in the terms the operator cares about — `$`/converged predicate
  and cached-vs-fresh deltas — instead of an ambiguous token total.
- ADR-0035 tiering gains a real cost signal: "escalate when the cheaper rung's
  cost-per-converged-predicate exceeds the next rung's expected cost," not just
  "escalate on stuck."
- Per-harness usage fidelity becomes visible, which itself is a harness-onboarding
  quality signal (ADR-0022): a harness that reports `none` is a worse economy
  citizen, and that is now measurable.
- Risk: providers change their usage JSON shapes. Mitigation: parse defensively per
  profile, keep raw usage alongside the normalized envelope, and add a live smoke
  test per harness that asserts the current shape still maps (the proposal flags this
  for Codex specifically).
- Risk: `cost_usd` requires a price table that drifts as providers reprice.
  Mitigation: a single versioned price map, dated; when a model is absent from the
  map, report tokens with `cost_usd` absent rather than guessing.

## Alternatives rejected

- **Keep the single `tokens` integer.** Cheapest, but makes the entire token-economy
  thesis unfalsifiable — cached and fresh tokens, the whole point of the caching
  work, are indistinguishable. Rejected as self-defeating for this program.
- **Compute cost only in an external observability tool (Langfuse/Helicone).** Useful
  for kazi's own benchmark harness, but the per-iteration JSON contract is what outer
  agents branch on; the envelope must live in the contract, with external tools as an
  optional sink, not the source of truth.
- **Make `cost_usd` mandatory.** Forces a guess for harnesses/models without a price,
  inviting fabricated numbers. Optional-with-fidelity-marker keeps it honest.
</content>

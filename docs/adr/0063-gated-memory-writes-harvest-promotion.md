# ADR 0063: Memory writes are gated -- debrief harvest, propose-then-confirm promotion, provenance, decay

## Status

Accepted

## Date

2026-07-07

## Refines

ADR-0060 (guardrail 2 is this ADR's law), ADR-0062 (the write path for the
corpus 0062 only reads), ADR-0058 (extends the learned-budget
propose-then-confirm pattern from numbers to prose), ADR-0049 (reuses the
list-proposed/approve verb shape), ADR-0042 (the inner agent can never write
its own grader OR its own memory), ADR-0036 (harvested knowledge routes into
the same doc tiers the doc-lifecycle goal maintains), ADR-0034 (memory
changes land as reviewed diffs, like all docs).

## Context

ADR-0062 gives kazi budgeted recall over a git-native corpus; recall quality
is bounded by corpus quality, and today the corpus grows only when a human
remembers to write. Yet the loop is constantly generating the raw material:
a predicate that wedged three different goals the same way is a landmine; a
debrief hypothesis (ADR-0058) that recurs across runs is a finding; an
economy pattern ("this repo's test suite makes `http` probes flaky") is a
convention the next goal should inherit. Left unharvested, this knowledge
dies in run sinks.

The danger in harvesting is exactly the one ADR-0058 named for prompting:
an agent free-writing its own long-term beliefs is a confabulation amplifier
and a gaming surface. A wrong lore entry is WORSE than none -- it is injected
as trusted context into every future relevant dispatch, compounding the error
at recall time. Nothing may cross from "what a model said" to "what the
project believes" without a human gate. There is also a hygiene constraint:
this pattern must not leak operator-internal detail into a public repo's
docs (ADR-0034), which is another reason a human reviews every promotion.

## Decision

1. **Harvest at debrief, into proposals -- never into the corpus.** At
   terminal projection (converged, stuck, or over-budget alike -- failures
   teach the most), a harvest pass runs controller-side and emits CANDIDATE
   memory entries to a `proposed_memories` read-model table (mirroring
   `proposed_goals`, ADR-0049). Sources, in trust order: deterministic
   pattern detectors first (recurring error fingerprints across goals via the
   ADR-0061 ledger, repeated `debrief_hypotheses`, cause-class clusters from
   the ADR-0058 economics); optionally ONE bounded model pass to draft
   human-readable phrasing of a detector hit. The model may word a candidate;
   only a detector may originate one.

2. **Every proposal carries provenance, mandatorily.** Run ids, goal refs,
   iteration numbers, and evidence pointers (predicate id + error
   fingerprint) travel with the entry -- machine fields on the proposal and a
   compact trailer on the written entry (the `kx:<sig>` convention from the
   ADR-0036 extraction tooling), so any belief can be traced to the facts
   that motivated it and re-proposals are idempotent.

3. **Promotion is a human-approved diff to repo files.** `kazi memory
   list-proposed` / `approve <id>` / `reject <id>` (all `--json`, ADR-0023;
   exposed via `kazi mcp`, ADR-0044). Approval writes the entry into the
   target corpus file routed by class -- invariant/landmine to the lore file,
   finding/benchmark to the devlog, decision-shaped to a drafted ADR stub
   (the ADR-0036 tier map) -- as an ordinary working-tree edit the operator
   lands through normal review (ADR-0034). kazi never commits memory on its
   own authority. Rejection records the fingerprint so the same candidate is
   not re-proposed.

4. **The inner agent has no write path, structurally.** Harvest runs
   controller-side after the run; during a run, corpus files are eligible
   `read_only_paths` (ADR-0042/0062). A dispatched model asking to "note this
   for the future" produces, at most, material a detector may later
   corroborate -- it cannot mint beliefs.

5. **Decay is explicit and verifiable.** Every harvested entry carries its
   date and provenance; an entry MAY carry a machine-checkable claim
   reference (a predicate-shaped check that re-verifies it, e.g. "this flag
   still exists"), making the belief re-testable the same way goals are. The
   standing doc-lifecycle goal (ADR-0036) gains a ratchet over
   stale-or-unverifiable entry count, so the corpus is pruned by the same
   propose-and-confirm loop that grows it. Un-decayed wrong beliefs are the
   layer's failure mode; decay is not optional polish.

6. **Rent applies here too (ADR-0060 guardrail 4).** The harvest ships when
   its consumers do it justice: measured as recall-hit-rate of harvested
   entries in later runs and their effect on convergence economics -- a
   harvest that fills the corpus with never-recalled entries is noise
   generation and gets narrowed.

## Consequences

- The full lifecycle closes: run facts (0061) -> detector candidates ->
  human-approved beliefs (this ADR) -> budgeted recall into future dispatches
  (0062) -> measured effect (0046/0058). Every arrow is either deterministic
  or human-gated; no free-running model writes at any point.
- The operator gains a small recurring review duty (triaging proposals).
  Mitigations: detectors-first origination keeps volume low and precision
  high; rejection memory prevents nagging; batching at debrief means no
  mid-run interruptions.
- `proposed_memories` + verb plumbing is one more read-model table and CLI
  surface, documented with the code (ADR-0034): `kazi help`, `AGENTS.md`,
  and the skill text gain the memory verbs in the same change that ships
  them.
- Public-repo hygiene gets a second reviewer by construction: nothing reaches
  a committed doc without a human reading it (ADR-0034's leak gate applies
  to the diff as usual).

## Alternatives rejected

- **Auto-append to lore with post-hoc review.** Inverts the gate: wrong
  beliefs are live (and being recalled into dispatches) until someone
  notices. The compounding failure mode this ADR exists to prevent.
- **Model-originated proposals (ask the agent what it learned).** The
  ADR-0058 confabulation/gaming objection, now aimed at permanent state.
  Detectors originate; models may only phrase.
- **Harvest into a private store instead of repo docs.** Splits project
  knowledge into a reviewed public tier and an unreviewed shadow tier that
  drifts; violates ADR-0060 guardrail 1 and reintroduces the vault.
- **No decay (append-only lore).** A corpus that only grows converges on
  being wrong; recall injects the wrongness under a token budget, crowding
  out the true entries. Decay is what makes guardrail 1's trust claim
  ("memory you can trust") hold over time.

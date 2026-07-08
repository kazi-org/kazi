# ADR 0060: Memory is kazi-core -- four layers of controller state, one owner, three guardrails

## Status

Accepted

## Date

2026-07-07

## Refines

ADR-0001 (positioning: an outer-loop reconciler), ADR-0008 (kazi owns context;
stateless per-iteration inner calls), ADR-0046/ADR-0058 (the economy envelope
and its persisted run economics ARE one of the four layers). Rejects the
alternative of a sibling memory tool outside this repo. Detailed mechanisms are
split into ADR-0061 (episodic ledger), ADR-0062 (semantic recall), and
ADR-0063 (gated memory writes); this ADR fixes the ownership map and the
invariants those three must hold.

## Context

kazi's loop is stateless per iteration by design (ADR-0008): every dispatch is
a fresh `claude -p`-class call fed a deterministic projection of the CURRENT
error (failing predicates + evidence, ADR-0009/0010). That design is a P-only
controller: it reacts to present error with no memory of past error. P-only
controllers oscillate -- and the fleet data shows exactly that. In a live
operator read-model (100 finished runs), the cheapest tier converged 33 runs
but went stuck or over-budget on 19 (~37% of its outcomes), versus ~13% for the
mid tier; inspection of stuck transcripts shows the classic signature: the
inner model re-attempts a previously failed approach because nothing tells it
the approach was already tried.

Meanwhile, the memory kazi DOES have is fragmented and mostly unconsumed:

- **Working memory** (this iteration): evidence projection + orientation pack
  (ADR-0009/0010) -- healthy, tiered per ADR-0047.
- **Episodic memory** (this goal, across iterations/runs): the read-model
  records every iteration, and ADR-0058's debrief writes `debrief_hypotheses`
  -- but NOTHING projects any of it back into the next dispatch. The loop's
  own history is invisible to the model doing the work.
- **Semantic memory** (this project, across goals): invariants, landmines, and
  conventions live in operator-personal skill conventions and ad-hoc markdown
  -- the exact "audience of one" failure ADR-0052 rejected. The pluggable
  retrieval seam (ADR-0012) and the context_store layer (ADR-0045) were built
  for this, but the shipped Gist provider never engages in practice (the
  4000-byte provider evidence cap sits below the 5120-byte store threshold),
  and the one retrieval backend was retired as never-functional (ADR-0052).
- **Statistical memory** (cross-project): persisted run economics + learned
  budget proposals (ADR-0046/0058) -- shipped, and the one layer with a
  working feedback loop.

The open design question this ADR settles: does kazi own all four layers, or
do the homeless two (episodic, semantic) move to a sibling tool? Two facts
decided it. First, memory quality in kazi's world is MEASURABLE only inside
kazi: "did this injected slice reduce iterations-to-converge per token?" is a
join between memory decisions, predicate verdicts, and the economy envelope --
all in the read-model. A sibling tool cannot close that loop without coupling
so deep it is a module wearing a repo costume. Second, seams on the hot path
have repeatedly failed silently in this project: the ADR-0045 provider that
never engaged (T35.10), the standalone-dashboard supervision list that ran
neither the run reaper nor log rotation while both sat correctly wired in a
tree production never boots. A separate memory tool adds a permanent seam --
its own release cadence, version skew, and threshold mismatches -- on the
single most-executed path in the product (every dispatch). The reuse argument
for a sibling also dissolves: `kazi mcp` (ADR-0044) already exposes kazi verbs
to any MCP client, so an interactive session can query the same memory the
loop uses without a second tool existing.

## Decision

1. **kazi owns all four memory layers.** Memory is not a feature adjacent to
   the controller; it is the controller's state, at four timescales:

   | Layer | Timescale | Content | Mechanism (owning ADR) |
   |---|---|---|---|
   | Working | this iteration | failing predicates, evidence, orientation | evidence projection + orientation pack (0009/0010/0047) -- exists |
   | Episodic | this goal | what was tried, what changed, what didn't | attempt ledger (0061) -- new |
   | Semantic | this project | invariants, landmines, conventions | git-native recall (0062) -- new |
   | Statistical | cross-project | cost/outcome by goal shape and model | economy envelope + learned budgets (0046/0058) -- exists |

   In control terms: working memory is the proportional input, episodic is the
   integral term, statistical is gain scheduling, semantic is the plant model.
   A reconciler without the integral term repeats its own failed corrections;
   adding it is completing the controller, not expanding the mission.

2. **Guardrail 1 -- librarian, never vault.** For the semantic layer, the
   durable format is git-versioned markdown in the workspace repo. kazi owns
   the MACHINERY (indexing, budgeted recall, harvest proposals) and never
   becomes the store of record: if kazi vanished, the project's memory remains
   `cat`-able files under review in git. No opaque memory database. (Episodic
   and statistical state are run FACTS, not knowledge, and live in the
   read-model like every other run fact.)

3. **Guardrail 2 -- gated writes.** Machine-written memory is restricted to
   recorded facts (iteration outcomes, verdict transitions, economics).
   Anything that expresses a BELIEF about the project -- a lore entry, a
   landmine, a convention -- reaches the semantic layer only through
   propose-then-confirm (ADR-0063), the same discipline as learned budgets
   (ADR-0058) and proposed goals (ADR-0049). The inner agent never writes
   memory directly; memory files are eligible `read_only_paths` under
   ADR-0042 enforcement during a run.

4. **Guardrail 3 -- every layer pays rent, measured.** Each new injection
   (ledger, recall slice) is a lever the ADR-0046 envelope must benchmark:
   convergence-per-token with and without, on real goals. A memory lever that
   does not move stuck rate, iterations-to-converge, or cost-to-converge is
   removed. This is ADR-0047's gate-on-measurement discipline applied to
   memory, and it is what keeps "kazi stays focused" an empirical invariant
   rather than an aesthetic one.

5. **One surface.** Memory is operated through a `kazi memory` verb family
   (recall / status / list-proposed / approve / reject -- shapes fixed in
   0062/0063), exposed like every other verb via `--json` (ADR-0023) and
   `kazi mcp` (ADR-0044). No new binary, no new repo, no new seam.

## Consequences

- ADR-0008's "stateless per iteration" is refined, not repealed: inner calls
  stay stateless; the CONTROLLER carries state and projects a bounded,
  deterministic digest of it into each dispatch (ADR-0061). The properties
  0008 bought -- reproducibility, no hidden session accretion -- are preserved
  because every injected byte derives from the read-model or repo files.
- ADR-0045's external-provider ambition retires. The context_store behaviour
  remains as an internal seam, but the first-party FTS path (ADR-0062) is the
  default and the Gist provider is legacy; its engagement-threshold mismatch
  becomes moot rather than fixed.
- ADR-0012's pluggable-retrieval seam is retained (per ADR-0052) with the
  ADR-0062 FTS backend as the first functional default.
- The read-model gains memory tables (attempt ledger projections, proposed
  memory entries) -- same WAL SQLite, no new dependency. Embeddings/vector
  search are explicitly NOT adopted here; promoting beyond FTS requires a
  benchmark and a superseding ADR.
- A sibling memory repo in the org is off the table while this ADR stands.
  (An org-level skills repo for orchestration POLICIES is unaffected --
  policies still live outside core per ADR-0035/0056.)

## Alternatives rejected

- **Sibling memory tool in the org.** Rejected for the two reasons above
  (unclosable feedback loop; a permanent silent-failure seam on the dispatch
  path) plus adoption reality: a memory tool that is not in the loop's write
  path ends up adjacent and unconsumed. `kazi mcp` already provides the
  cross-consumer reuse a sibling would have offered.
- **Adopt an existing third-party memory tool.** The available tools are
  chat-session recorders: DB-centric stores of conversation observations, no
  token-budgeted recall contract, no gated promotion, no way to join memory to
  convergence outcomes. The niche kazi needs -- memory for verification-driven
  loops dispatching cheap stateless models -- is not what they build, and
  depending on an external roadmap for controller state is the coupling this
  ADR exists to avoid.
- **All four layers as repo files (no read-model state).** Episodic facts
  (per-iteration verdict transitions) are high-churn machine data; as markdown
  they would be merge-conflict fodder and would still need an index to be
  injectable under a token budget. Facts belong in the read-model; beliefs
  belong in git. The split IS the design.

# ADR 0061: Episodic memory -- a deterministic attempt ledger projected into every dispatch

## Status

Accepted

## Date

2026-07-07

## Refines

ADR-0060 (layer 2 of the four-layer map), ADR-0008 (the one principled
exception to per-iteration statelessness), ADR-0009/0010 (the ledger is a new
section of the same thin, deterministic projection), ADR-0047 (its size is a
context-tier lever), ADR-0058 (consumes the debrief signals 0058 records
write-only today).

## Context

Every iteration, the loop already RECORDS what happened: per-iteration rows in
the read-model (predicate verdicts, timing, usage), per-run sinks (events +
transcript, ADR-0057), and -- since ADR-0058 -- debrief hypotheses at terminal
projection. None of it is projected forward. The dispatch prompt describes the
present error only, so the inner model cannot distinguish "first attempt at
this predicate" from "fifth attempt; the previous four all touched the same
file and did not change the verdict." The observable failure mode is the
cheap-tier signature from ADR-0060's fleet data: re-attempting a known-failed
approach, oscillating between two non-solutions, or re-running discovery the
run already paid for. `decide/2` has PARTIAL history awareness
(`error_stuck?`, no-progress detection) but that intelligence stops at the
controller -- the one actor who could act on it, the dispatched model, never
sees it.

The design constraint that matters most is honesty. ADR-0058 explicitly
rejected model self-reports ("ask the model what it needed") as
confabulation-prone and a gaming surface. An attempt ledger built from
transcript summaries would inherit that flaw. The ledger must be built ONLY
from facts kazi itself observed and recorded.

## Decision

1. **A per-goal attempt ledger, derived (never authored).** The ledger is a
   deterministic fold over the read-model's iteration history for the current
   goal (and, when the goal-file identity matches, its prior runs): for each
   currently-failing predicate, the dispatches that targeted it, each
   dispatch's observable effect (verdict transition or none), the files
   touched (diff summary the loop already captures at integrate/verify), and
   the error fingerprint (predicate id + error class + normalized message
   head). No model-generated prose enters the ledger. It is a projection, not
   a document: recomputable from the read-model at any time, nothing new to
   keep consistent.

2. **Injected as a bounded section of the dispatch prompt.** The projection
   (ADR-0009) gains an `ATTEMPT LEDGER` section after evidence: most recent
   and most repeated attempts first, hard-capped (default on the order of
   ~800 tokens; exact cap is a context-tier parameter per ADR-0047, and tier 0
   MAY omit the ledger entirely). The high-value line it must always afford
   when true: "approach with fingerprint F was tried at iterations N, M and
   did not change predicate P's verdict -- do not repeat it."

3. **Repeat-attempt detection is a fingerprint, not a judgment.** Two attempts
   are "the same approach" when their (failing-predicate set, touched-file
   set, error-fingerprint) triple matches. Crude is acceptable and preferred:
   a false "this looks repeated" costs one line of prompt; a missed repeat
   costs a wasted dispatch. No semantic similarity, no model in the loop.

4. **`decide/2` reads the same ledger.** The existing stuck/no-progress
   heuristics and the ledger become views of one fold, so controller policy
   and inner-model context can never disagree about what history says. This
   also gives escalation (`[escalation]` data, ADR-0056) a sharper trigger
   than iteration count: "same fingerprint failed K times" is a
   model-capability signal, distinct from "budget consumed."

5. **Machine-written, facts only, run-scoped.** The ledger is trust-class
   "run fact" (ADR-0060 guardrail 2): written by the loop, never by the inner
   agent, never promoted to the semantic layer as-is. A recurring ledger
   pattern may MOTIVATE a semantic proposal (ADR-0063) -- e.g. the same
   landmine wedging three different goals -- but that crossing is gated.

6. **Pays rent before it stays (ADR-0060 guardrail 4).** Ship behind a flag,
   benchmark with the ADR-0046 envelope on real previously-stuck goals:
   iterations-to-converge, stuck rate, cost-to-converge, with/without the
   ledger at fixed model + budget. Promote to default-on only on a measured
   win; remove on a null result.

## Consequences

- The dispatch prompt grows one section; the stable orientation prefix
  (ADR-0010/T19.1) is unaffected because the ledger is volatile and sits with
  evidence, after the cacheable prefix.
- The read-model needs at most a light projection table (or view) over data
  already recorded; diff summaries not yet captured per-iteration become a
  loop responsibility at act/verify time -- recorded facts, no new deps.
- Cross-RUN episodic memory (same goal re-applied after a stop) comes free:
  the fold keys on goal identity, not run id, so a resumed goal starts with
  its history instead of amnesia.
- The known failure this targets is measurable in the fleet data (ADR-0060
  context); if the benchmark shows the cheap tier's stuck rate unmoved, the
  correct response is removal, not tuning forever.

## Alternatives rejected

- **Summarize the transcript into the next dispatch.** Model-authored memory:
  confabulation-prone, a gaming surface (ADR-0058), and it couples prompt
  quality to transcript verbosity. Facts only.
- **Session continuity (`claude -r` / persistent session) instead of a
  ledger.** Repeals ADR-0008 entirely: context accretes unboundedly, kazi
  loses control of what the model sees, reproducibility dies, and the
  cheap-tier context economy (ADR-0047) inverts. The ledger keeps
  statelessness while restoring exactly the state that matters.
- **Keep history controller-side only (status quo `decide/2`).** The
  controller can escalate or stop, but only the dispatched model can STOP
  REPEATING ITSELF; withholding history from the one actor able to act on it
  is the current bug, not a design.

# ADR 0035: Adaptive in-family model tiering is a SKILL recipe (escalate on stuck), never kazi-core policy

## Status
Accepted

## Date
2026-06-24

## Refines
ADR-0023 (the orchestrator owns the per-phase model policy; kazi exposes
`--harness`/`--model` and stays a pure tool) and ADR-0033 (the default "cheaper"
story is in-family Claude tiering: a frontier model authors predicates, a cheap
Claude model runs the grind). ADR-0033 established STATIC tiering. This ADR adds
the ADAPTIVE refinement -- start cheap, escalate the model when kazi reports the
loop is stuck -- and fixes WHERE that policy lives.

## Context

ADR-0033 made in-family Claude tiering the default cost story and shipped the
enabler (T19.6: the `claude` profile forwards `--model`). Two gaps remain:

1. **The skill's default recipe lags the decision.** The installed kazi skill and
   `AGENTS.md` teach two-tier economics but their worked examples still LEAD with
   the old local/opencode framing (`--harness opencode --model local/qwen3.6`),
   not the ADR-0033 in-family default (author on a frontier model, grind on
   Haiku/Sonnet via `--harness claude --model <id>`).

2. **Static tiering wastes the cheap tier's failures or the frontier tier's money.**
   A fixed "always Haiku" grind stalls on hard slices; a fixed "always Opus" grind
   pays frontier rates for trivial keystrokes. The efficient policy is adaptive:
   start on the cheapest capable model and escalate ONLY when the loop is not
   making progress.

kazi already emits the signal an adaptive policy needs: each `kazi apply --json`
iteration returns a `next_action` and convergence state (converging / stuck /
regressed / over-budget). An orchestrating agent can branch on that to choose the
next iteration's model. The open design question is whether the escalation policy
belongs INSIDE kazi or in the orchestrator.

## Decision

1. **The tiering + escalation policy is a SKILL recipe, owned by the orchestrator
   -- never kazi-core.** Putting a per-phase or per-difficulty model selector inside
   kazi is explicitly rejected (ADR-0033 already rejected hardcoding a tier in
   core; this ADR reaffirms it for the adaptive case). kazi exposes `--model` and
   reports state; the skill decides which model runs the next iteration. This keeps
   kazi an unopinionated controller and lets the policy evolve without a kazi
   release.

2. **The skill defaults to in-family Claude tiering.** The worked example becomes:
   author predicates on the session's frontier model (e.g. Opus) -> `kazi apply
   --harness claude --model <cheap-claude>` for the grind. Local/BYOM (opencode +
   Qwen/Llama) is kept as the PRIVACY add-on, demoted below the in-family default
   (ADR-0033 ranking).

3. **The escalation ladder is a bounded, skill-side state machine.** Start on the
   cheapest capable model (e.g. Haiku); on a kazi-reported stuck / no-progress /
   regression signal for the same slice, re-dispatch the next `kazi apply` with the
   next model up the ladder (Haiku -> Sonnet -> Opus). The ladder is CAPPED (it
   tops out at the frontier model and stops escalating) and bounded by kazi's
   existing budget/stuck termination so it cannot loop or burn unboundedly.

4. **kazi's job is signal sufficiency, not policy.** If kazi's `--json` does not
   already expose enough state for the skill to detect "stuck on this slice N times"
   reliably, the only permitted kazi change is enriching that REPORTED STATE (a
   read-only signal), never adding model-selection logic. This is verified before
   any code change; the default expectation is no kazi-core change at all.

5. **The claim stays honest until measured.** The benchmark (E19/T19.7, extended
   with the escalating arm) must report convergence RATE + correctness alongside $
   and tokens, so a "cheaper but escalates to frontier every time" or a
   "cheaper but fails" outcome is caught, not hidden. Model ids in all examples are
   real current ids checked against the claude-api reference, never invented.

## Consequences

- The skill finally defaults to the broadly-applicable cost story (ADR-0033) and
  adds an efficiency win (pay frontier rates only for the slices that actually need
  them) with zero kazi-core change in the default path.
- The escalation policy can be tuned (ladder, thresholds) purely in the skill, so
  it improves without shipping a kazi binary.
- Risk: escalation that triggers too eagerly collapses to "always frontier" (no
  saving) and too lazily wastes cheap-tier iterations; the benchmark + a tunable
  stuck-threshold mitigate, and the predicates make a wrong tier visible (it fails
  to converge), never a false done.
- Risk: if kazi's reported state turns out insufficient, a small signal enrichment
  is needed (read-only) -- bounded and verified up front (decision 4).
- kazi stays a pure tool; all model judgment remains in the orchestrator, so the
  controller's positioning (ADR-0001/0023) is intact.

## Alternatives rejected

- **Auto-tiering inside kazi (pick the model by phase/difficulty in core).** The
  derail: it makes kazi opinionated about models, violates ADR-0023/0033, and
  couples policy to the release cycle. Rejected.
- **Static tiering only (fixed cheap grind, no escalation).** Simpler but stalls on
  hard slices or overpays; the adaptive ladder is the headline efficiency. Kept as
  the fallback the ladder degenerates to when escalation is disabled.
- **A separate "tier-manager" daemon.** Over-engineered; the skill state machine
  over kazi's existing `--json` signal is sufficient single-node.

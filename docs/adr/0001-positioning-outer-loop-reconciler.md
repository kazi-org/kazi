# ADR 0001: Positioning — an outer-loop reconciler, not a harness

- Status: Accepted
- Date: 2026-06-21

## Context

The temptation when building agent tooling is to build a *harness* — the thing
that runs the agent loop and that the human types into (Claude Code, Codex,
claw-code, ruflo). That market is crowded, fast-moving, and backed by the model
labs themselves. Competing there means perpetually chasing Anthropic and OpenAI,
and re-implementing a moving target. ruflo demonstrates the failure mode:
"swarm" features that are coordination theatre because the real work still
bottoms out on someone else's harness.

Separately, two real gaps exist that no harness owns: (1) "done" is the agent's
subjective opinion, and (2) parallel agents have no real coordination.

## Decision

kazi is the **outer loop**, not a harness. It treats existing coding agents as a
replaceable inner loop, invoked through a thin **harness adapter** (subprocess:
`claude -p`, Codex, etc.). kazi owns only the layer none of them own:
**convergence + coordination + objective truth.**

The mental model is a control/reconciliation loop (Kubernetes reconciles infra
to desired state) applied to coding goals: desired state = a predicate set;
actual state = predicate evaluation; reconcile action = dispatch an agent.

## Consequences

- kazi rides harness improvements instead of competing with them; a better
  Claude Code makes kazi better at no cost.
- The harness boundary is a subprocess + structured I/O, so it is language- and
  vendor-neutral.
- kazi must define a clean adapter contract (invoke with a focused prompt +
  failing-predicate evidence; capture result, diff, cost).
- We explicitly will NOT ship a terminal/REPL/IDE. If users want to type at an
  agent, they use their harness; kazi conducts it.

## Alternatives rejected

- **Fork/adopt a harness (claw-code, ruflo).** Owning a Claude Code competitor
  is a maintenance tar pit with no commercial return for the maintainer; ruflo
  also imports marketing-over-substance risk.
- **Build a new harness from scratch.** Same competition problem, larger.

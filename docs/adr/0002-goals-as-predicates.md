# ADR 0002: Goals are machine-checkable predicate sets

- Status: Accepted
- Date: 2026-06-21

## Context

The deepest weakness in agentic workflows is that completion is the agent's
self-report. Prose goals ("make the tests pass and clean it up") and long
verification checklists do not fix this: an agent that skips a step still claims
success. Any loop built on "the agent thinks it's done" inherits this and either
stops early or runs forever.

## Decision

A **goal** is a declarative set of **predicates**, each evaluated by a pluggable
**predicate provider** returning `{pass | fail, evidence}`. The goal is met iff
every predicate evaluates `true`. **Truth lives in the controller, not the
agent.** The convergence loop may only terminate as `converged` when the full
predicate vector is true, with the supporting evidence persisted.

A goal also carries:

- **guard predicates** — invariants that must never regress (test-count must not
  drop, coverage must not fall below baseline). These prevent the agent from
  "passing" a predicate by deleting the check.
- **budget** — a hard token / wall-clock / iteration ceiling.
- **scope** — the repo and paths agents may touch.

Predicate providers are adapters: `tests`, `coverage`, `http_probe`,
`prod_logs`, `lint`, `custom_script`. New goal types are new providers, not core
changes.

## Consequences

- "Done" is objective and auditable; every termination has stored evidence.
- The failing predicates are the work-list — dispatch is derived from state, not
  guessed.
- Providers must report enough structured evidence to (a) prove pass/fail and
  (b) seed the fixer agent's context.
- Providers must support re-run/quarantine so flaky results do not poison the
  loop (see concept §5).
- `/qualify` becomes the goal `{unit, integration, api, browser, prod_logs}` —
  no longer a checklist skill.

## Alternatives rejected

- **LLM-as-judge for completion.** Reintroduces subjective truth and is gameable;
  acceptable at most as *one* predicate among objective ones, never as the gate.
- **Single pass/fail exit code.** Too coarse: loses the per-predicate vector
  needed for regression detection and targeted dispatch.

# ADR 0011: Slice-3 operator surfaces (LiveView dashboard + Telegram bridge)

## Status
Accepted (the Telegram-bridge portion is SUPERSEDED by ADR-0029 -- the bridge is
dropped because the orchestrating agent is the human's mobile interface; the
LiveView dashboard and the `Kazi.Authoring` write path are unaffected)

## Date
2026-06-22

## Context

Slice 3 adds human-facing operator surfaces on top of the reconciler core:
a Phoenix LiveView dashboard (UC-018: goal board, presence, lease map, history)
and a Telegram bridge (UC-019: goal-in / ping-out). These are the first surfaces
that let a human watch and steer kazi without reading the CLI/read-model directly.

The risk is coupling. kazi's core is a harness-agnostic outer-loop reconciler
(ADR-0001) whose only inputs are goals-as-predicates (ADR-0002) and whose state
lives in the SQLite read-model (ADR-0005) and the NATS coordination substrate
(ADR-0004, leases per ADR-0006). If a dashboard or a chat bridge reaches into the
loop's `:gen_statem` or the harness adapter, every UI change risks destabilizing
convergence, and the controller stops being harness/transport-agnostic.

We must also decide the web stack. The project conventions (CLAUDE.md) permit
Phoenix LiveView starting at Slice 3; before Slice 3 it was explicitly NOT a
dependency to keep the walking skeleton thin (ADR-0007).

## Decision

1. **Phoenix LiveView is the dashboard stack.** Add Phoenix + LiveView as Slice-3
   dependencies. The dashboard is a thin, read-mostly projection.

2. **Operator surfaces are READ projections over existing state; they never couple
   into the core loop.** The dashboard and the Telegram bridge read from the
   `Kazi.ReadModel` (goals, iterations, history) and from NATS presence/intent +
   lease state (ADR-0004/0006). They subscribe; they do not call into `Kazi.Loop`
   or `Kazi.Harness.*`. The only WRITE path a surface may trigger is goal
   authoring/approval (UC-017), and that goes through the same `Kazi.Authoring`
   API the CLI uses -- never a back-door into a running reconciliation.

3. **Both surfaces sit behind injectable seams so they are hermetically testable.**
   The Telegram client is a behaviour with an in-memory test double (no real bot
   token or network in tests). The dashboard's data sources (read-model query +
   presence/lease source) are injected, so LiveView tests and Playwright browser
   tests run against fixtures with no NATS server and no live harness.

4. **Walking-skeleton order (ADR-0007):** authoring (UC-017) lands first as a
   CLI + read-model capability; the LiveView dashboard and Telegram bridge then
   consume it. A surface is never the only way to reach a capability.

## Consequences

Positive: the core reconciler stays harness- and transport-agnostic and keeps its
test isolation; UI/transport churn cannot regress convergence; surfaces are
hermetically testable without a browser-to-NATS-to-harness stack; the dashboard is
a small, replaceable projection.

Negative: a read-only dashboard cannot drive a reconciliation directly (by design)
-- steering goes through the authoring API, which is a deliberate extra hop. Adding
Phoenix grows the dependency surface and the supervision tree. Deploying the
dashboard as a live production surface is a separate infra step (hosting + the
production-deploy/verify chain) and is tracked as its own task rather than bundled
into the feature work.

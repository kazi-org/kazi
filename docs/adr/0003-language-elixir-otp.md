# ADR 0003: Runtime — Elixir / OTP + Phoenix LiveView

- Status: Accepted
- Date: 2026-06-21

## Context

kazi's core is not a batch program; it is a long-running population of
supervised, fallible, concurrent processes: one reconciliation loop per active
goal, a supervisor per dispatched agent, watchers for leases and predicates, and
a live console over all of it. The maintainer (an AI assistant) writes the code,
so "easy for a human team to hand-maintain" is not a tiebreaker — best fit for
the problem is. Performance is irrelevant: the loop is LLM/network-bound, not
CPU-bound.

## Decision

Build the controller and dashboard in **Elixir / OTP**, with **Phoenix
LiveView** for the live console.

Domain → runtime mapping:

| kazi needs | OTP provides |
|---|---|
| stateful loop per goal that survives failure | `GenServer` / `GenStateMachine` under a supervisor |
| spawn many fallible agents; restart/escalate; isolate failures | supervision trees |
| stuck/oscillation handling as first-class | per-goal process state + timeouts + circuit breakers |
| real-time dashboard | Phoenix LiveView (no separate SPA) |
| live agent↔agent channel | Phoenix PubSub / `:pg` |
| drive `claude -p`, test runners | Ports / `System.cmd` (language-neutral) |

Integration boundaries (harness adapters, predicate providers, NATS) are
subprocesses or wire protocols, so polyglot cost is near zero.

## Consequences

- Supervision/restart/escalation and live UI are native, not hand-rolled — the
  exact paths ("agent crashed mid-task") that bite hand-rolled orchestrators.
- Libraries: `Gnat` + `jetstream` (NATS), `Exqlite`/Ecto SQLite3 (read-model),
  Phoenix LiveView (console).
- The team must be fluent in Elixir; acceptable while the maintainer is an AI
  assistant and the tool is internal-first.

## Alternatives rejected

- **Go** — the only serious alternative (NATS-native, single binary, matches an
  existing Go stack the maintainer runs). Rejected because supervision trees and
  the live-update layer must be built by hand; chosen as the fallback if OTP is
  overruled.
- **Rust** (claw-code's path) — pays async-strictness tax on the parts that
  change most (providers, adapters) to buy performance the loop does not need.
- **TypeScript / Python** — weaker for a robust always-on supervised daemon.

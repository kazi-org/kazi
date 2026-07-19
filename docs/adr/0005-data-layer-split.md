# ADR 0005: Data-layer split (Git / JetStream / ETS / SQLite)

- Status: Accepted
- Date: 2026-06-21
- Depends on: ADR-0003 (Elixir/OTP), ADR-0004 (JetStream)

## Context

A foundational requirement: design the *final* data architecture now and never
swap a store later. The way to guarantee that is to give each store exactly one
job so none ever has to grow into another's role. The temptation to avoid is one
store doing live coordination, durable truth, and analytics queries at once —
which forces a migration when one role outgrows the chosen engine.

## Decision

Four layers, each authoritative for exactly one concern (CQRS):

| Store | Authoritative for | Notes |
|---|---|---|
| **Git** | CODE | branches, worktrees, PRs (unchanged) |
| **NATS JetStream** | COORDINATION | KV leases (CAS + TTL), KV goals, `kazi.events` stream, presence/intent subjects (ADR-0004) |
| **BEAM / ETS** | LIVE working set | current predicate vector, in-flight agents, lease cache; drives LiveView; rehydrated from JetStream on restart |
| **SQLite (WAL, Exqlite)** | local READ-MODEL | predicate/lease history + convergence analytics, projected from `kazi.events`; rebuildable, **never** authoritative |

JetStream is the only coordination truth; SQLite is a disposable projection of
it; ETS is the live in-memory cache; Git owns code.

## Consequences

- No store is doing a job it will outgrow, so none gets swapped — the stated
  requirement is met by construction.
- The dashboard reads live state from ETS (instant) and history from SQLite
  (SQL: joins, indexes, aggregation) — no analytics rebuilt from stream replay
  per query.
- SQLite can be deleted and rebuilt from the JetStream stream at any time.
- Single-machine vs multi-machine does not change the layering.

## Alternatives rejected

- **SQLite as coordination truth** — its multi-process WAL is fine locally but it
  is not a distributed CAS or live bus; would force a later swap.
- **bbolt/boltdb for local state** — single-writer-process file lock; blocks
  multi-process access (multiple agent sessions), and KV-only loses SQL for the
  ledger.
- **JetStream only (no SQLite)** — rebuilding analytics from stream replay on
  every query is wasteful and the dashboard genuinely wants SQL.
- **A vector DB (RuVector/AgentDB) in the core** — solves a problem the
  deterministic loop does not have; deferred to a later pluggable memory adapter.

# kazi

**A reconciliation controller for software goals.**

*kazi* (Swahili: *work / a job*) is the outer loop that existing coding agents
lack. You declare a goal as a set of machine-checkable predicates; kazi observes
actual state, and when it differs from the goal, it dispatches coding agents to
close the gap — looping until the goal is objectively met, the work is stuck, or
the budget is spent.

It is **not** another coding agent or terminal. kazi *drives* the harnesses you
already use (Claude Code, Codex, ...) the way a control loop drives a system
toward desired state — the way Kubernetes reconciles infrastructure, but for
agentic coding goals.

```
declare desired state  ──►  kazi observes actual state  ──►  dispatch agents to
(predicate set)             (evaluate predicates)            close the gap
        ▲                                                          │
        └───────────────  loop until reconciled  ◄────────────────┘
```

## Why it exists

Two gaps nobody owns:

1. **"Done" is the agent's opinion.** Coding agents stop when they *think* they
   are finished. kazi makes done objective: the loop cannot terminate as success
   unless every predicate evaluates true, with stored evidence.
2. **Parallel agents collide.** Mutual exclusion on task identity (lock the
   task) does not stop two agents editing the same files. kazi coordinates on
   *resources* (blast-radius leases) over a live bus, so concurrent sessions
   converge instead of conflict.

## Status

Pre-implementation. The design is frozen in [`docs/concept.md`](docs/concept.md)
and the [ADRs](docs/adr/). Code has not started.

## Design at a glance

- **Runtime:** Elixir / OTP + Phoenix LiveView ([ADR-0003](docs/adr/0003-language-elixir-otp.md))
- **Coordination truth:** NATS JetStream — KV + streams ([ADR-0004](docs/adr/0004-coordination-substrate-nats-jetstream.md))
- **Data split:** Git (code) · JetStream (coordination) · ETS (live state) · SQLite (read-model) ([ADR-0005](docs/adr/0005-data-layer-split.md))
- **Goals:** machine-checkable predicate sets, evidence-backed ([ADR-0002](docs/adr/0002-goals-as-predicates.md))
- **Positioning:** harness-agnostic outer loop, never a harness ([ADR-0001](docs/adr/0001-positioning-outer-loop-reconciler.md))

## License

MIT.

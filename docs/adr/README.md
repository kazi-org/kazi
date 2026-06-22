# Architecture Decision Records

Each ADR captures one decision: the context, the decision, the consequences, and
the alternatives rejected. ADRs are immutable once accepted — to change a
decision, write a new ADR that supersedes the old one (and update
[`../concept.md`](../concept.md)).

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-positioning-outer-loop-reconciler.md) | Positioning: an outer-loop reconciler, not a harness | Accepted |
| [0002](0002-goals-as-predicates.md) | Goals are machine-checkable predicate sets | Accepted |
| [0003](0003-language-elixir-otp.md) | Runtime: Elixir / OTP + Phoenix LiveView | Accepted |
| [0004](0004-coordination-substrate-nats-jetstream.md) | Coordination substrate: NATS JetStream | Accepted |
| [0005](0005-data-layer-split.md) | Data-layer split (Git / JetStream / ETS / SQLite) | Accepted |
| [0006](0006-coordination-leases-and-graph-partitioning.md) | Coordination by resource leases + graph partitioning | Accepted |
| [0007](0007-build-strategy-walking-skeleton.md) | Build strategy: walking skeleton (idea → production) | Accepted |
| [0008](0008-harness-invocation-and-context.md) | Harness invocation: headless, stateless per iteration; kazi owns context | Accepted |
| [0009](0009-prompt-construction-thin-evidence-projection.md) | Prompt construction: a thin, deterministic evidence projection | Accepted |

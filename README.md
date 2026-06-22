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

Slices 0–3 are implemented and green (Elixir/OTP; ~700 hermetic ExUnit tests). The
design is in [`docs/concept.md`](docs/concept.md) and the [ADRs](docs/adr/); the
live build plan is [`docs/plan.md`](docs/plan.md). What works today:

- **Convergence core (Slice 0).** The reconcile loop (`:gen_statem`) drives a
  goal-file's predicates to truth via a stateless `claude -p` harness plus
  integrate (branch → PR → rebase-merge) and deploy actions; every iteration is
  persisted to a SQLite read-model.
- **Trustworthy loops (Slice 1).** Regression detection, flake quarantine, hard
  budget ceilings (iterations / wall-clock / tokens), stuck-escalation, and a
  production-log predicate.
- **Creation mode (Slice 2).** kazi builds *new* features from failing acceptance
  predicates, not only repairs existing behaviour. From Slice 2 on, kazi builds kazi.
- **Slice 3.** NATS JetStream resource leases (revision-CAS + per-key TTL) with
  presence/intent, graph-aware blast-radius partitioning, idea → acceptance-predicate
  authoring (with a CLI), a Phoenix LiveView dashboard (goal board, presence/lease
  map, per-goal history), and a Telegram goal-in / ping-out bridge.
- **Context injection.** Each stateless iteration starts *oriented* — a
  deterministic blast-radius orientation pack, an optional SHA-cached
  semantic-retrieval adapter, and a bounded working-set digest — without
  reintroducing conversation memory ([ADR-0010](docs/adr/0010-context-injection-reexploration-mitigation.md)).

The live production dogfood (**T0.12**) is **done**: kazi drove the
`fixtures/deploy-target` service from a deliberately failing test to a verified
Cloud Run deployment — dispatching an agent to make the fix, integrating it (PR →
rebase-merge), deploying, and confirming the live `/livez` endpoint returns `ok` —
and refused to call it converged until *both* the unit test and the live probe
passed. The idea → production loop is closed end-to-end.

## CLI: `kazi run`

Drive a goal-file to convergence against an explicit target workspace
(`UC-004`):

```
kazi run <goal-file> --workspace <path>
```

- `<goal-file>` — a TOML goal-file (schema in `Kazi.Goal.Loader`; see the example
  at [`priv/examples/deploy_target.toml`](priv/examples/deploy_target.toml)).
- `--workspace <path>` — the target workspace where edits / integrate / deploy
  operate. Falls back to the goal-file's `[scope]` workspace when omitted.
- `--help` — usage.

The command loads the goal, runs the reconcile loop via `Kazi.Runtime`, prints a
human-readable outcome (converged / stopped) with the final predicate vector, and
exits `0` on convergence, non-zero otherwise.

### Two entry points

There are two equivalent ways to invoke it; they share the same `Kazi.CLI` core:

```sh
# 1. Mix task — the persistent default. Boots the full app (incl. the native
#    SQLite NIF), so every iteration is projected to the local read-model.
mix kazi.run priv/examples/deploy_target.toml --workspace ./fixtures/deploy-target

# 2. Escript — a self-contained `kazi` binary, convenient for distribution.
mix escript.build                 # produces ./kazi (gitignored — do not commit)
./kazi run priv/examples/deploy_target.toml --workspace ./fixtures/deploy-target
./kazi --help
```

> **Read-model note.** An escript archive cannot bundle a native NIF, so the
> escript runs **without** the SQLite read-model (it degrades gracefully with a
> warning; convergence still works). Use `mix kazi.run` when you want iterations
> persisted. The Mix task creates and migrates the read-model on startup, so a
> fresh checkout persists from the very first run.

## Design at a glance

- **Positioning:** harness-agnostic outer loop, never a harness ([ADR-0001](docs/adr/0001-positioning-outer-loop-reconciler.md))
- **Goals:** machine-checkable predicate sets, evidence-backed ([ADR-0002](docs/adr/0002-goals-as-predicates.md))
- **Runtime:** Elixir / OTP + Phoenix LiveView ([ADR-0003](docs/adr/0003-language-elixir-otp.md))
- **Coordination truth:** NATS JetStream — KV leases + streams ([ADR-0004](docs/adr/0004-coordination-substrate-nats-jetstream.md)), resource leases + graph partitioning ([ADR-0006](docs/adr/0006-coordination-leases-and-graph-partitioning.md))
- **Data split:** Git (code) · JetStream (coordination) · ETS (live state) · SQLite (read-model) ([ADR-0005](docs/adr/0005-data-layer-split.md))
- **Build strategy:** walking skeleton, idea → production from Slice 0 ([ADR-0007](docs/adr/0007-build-strategy-walking-skeleton.md))
- **Harness & context:** stateless per iteration; kazi owns context ([ADR-0008](docs/adr/0008-harness-invocation-and-context.md)), a thin deterministic evidence projection ([ADR-0009](docs/adr/0009-prompt-construction-thin-evidence-projection.md)), with blast-radius context injection ([ADR-0010](docs/adr/0010-context-injection-reexploration-mitigation.md)) and an optional pluggable retrieval-memory adapter ([ADR-0012](docs/adr/0012-pluggable-retrieval-memory-adapter.md))
- **Operator surfaces:** the LiveView dashboard and Telegram bridge are read projections decoupled from the core loop ([ADR-0011](docs/adr/0011-slice3-operator-surfaces.md))

## License

MIT.

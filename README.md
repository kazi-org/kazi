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

- **Runtime:** Elixir / OTP + Phoenix LiveView ([ADR-0003](docs/adr/0003-language-elixir-otp.md))
- **Coordination truth:** NATS JetStream — KV + streams ([ADR-0004](docs/adr/0004-coordination-substrate-nats-jetstream.md))
- **Data split:** Git (code) · JetStream (coordination) · ETS (live state) · SQLite (read-model) ([ADR-0005](docs/adr/0005-data-layer-split.md))
- **Goals:** machine-checkable predicate sets, evidence-backed ([ADR-0002](docs/adr/0002-goals-as-predicates.md))
- **Positioning:** harness-agnostic outer loop, never a harness ([ADR-0001](docs/adr/0001-positioning-outer-loop-reconciler.md))

## License

MIT.

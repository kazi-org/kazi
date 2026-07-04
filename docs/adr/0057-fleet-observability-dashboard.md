# ADR 0057: Fleet observability — the run registry, per-run sinks, and `kazi dashboard`

## Status
Accepted

## Date
2026-07-03

## Refines / depends on
ADR-0011 (the dashboard is a read-only projection, decoupled from the loop —
reaffirmed and extended here), ADR-0026 (kazi under an external pool — this
ADR subsumes its open observability tail, T20.8), ADR-0027/ADR-0028 (the
native scheduler + predicate-graph waves — the fleet view renders their
frontiers), ADR-0046 (per-iteration context/tool counters — drill-in data),
ADR-0055 (the implicit `landed` predicate — a node state in the fleet view),
ADR-0056 (the roadmap goal-DAG — the fleet view's future spine). Consistent
with ADR-0007 (no phase before its need): NATS fan-in stays in Slice 3.

## Context

The operator runs several concurrent sessions, each driving its own
`kazi apply`. Three structural disconnects make that fleet a black box:

1. **The workload is fleet-shaped; the dashboard is instance-shaped.** The
   LiveView surface (`dashboard`, `dag`, `goal_board`, `history`, `lease_map`)
   is a dev-server view of ONE BEAM node. A one-shot CLI run has no visible
   surface at all, and live in-node state (LeaseTable) is per-node by design.
   No single pane shows all N runs.
2. **The inner-harness transcript is discarded.** The read-model records the
   predicate vector and the ADR-0046 counters per iteration, but WHAT the
   inner agent did between iterations — the harness stream — is dropped or
   buried in stderr. "Why is this goal stuck?" cannot be answered from
   persisted state, live or post-mortem.
3. **The outer layer is invisible.** Which session drives which goal exists
   only as process state; a dead run leaves no registry entry to distinguish
   "converged and exited" from "crashed mid-iteration".

What already exists and is reused, not rebuilt: the shared per-user SQLite
read-model (WAL) that every instance on the machine writes (`goal_summary` +
`iterations` with full predicate-vector history), the LiveView assets, and
the loop's `stuck_detector` / `flake` / `regression_detector` — the attention
signals are already computed, just never surfaced fleet-wide.

A design exploration produced three rendered directions (an ops-center fleet
grid; an analyst drill-in built around a predicates-by-iterations convergence
heatmap plus a transcript tail; a spatial "starmap" of the goal DAG in wave
bands). The operator chose the **starmap** as the home view; the analyst
drill-in becomes the per-goal view; the grid's attention queue and event
river are absorbed into both.

## Decision

1. **The fleet dashboard is a read-only projection.** It renders state; it
   never mutates goals, dispatches, or leases (ADR-0011 reaffirmed at fleet
   scope). Control actions, if ever added, will shell through the existing
   CLI verbs in a later ADR — not bypass them.

2. **A run registry with heartbeats in the shared read-model.** Every
   `kazi apply` upserts a `runs` row (run id, pid, workspace, goal ref,
   harness/model, started_at, heartbeat_at, terminal status, sink paths) and
   heartbeats it each loop tick. Liveness is heartbeat staleness — no IPC, no
   port discovery; a SIGKILLed run is visibly stale rather than silently
   absent.

3. **Per-run append-only JSONL sinks.** Each run writes
   `events.jsonl` (loop events, per-iteration predicate vectors, verdicts)
   and `transcript.jsonl` (the harness stream, teed — tool calls and text as
   they happen) under a per-run directory in the kazi home. The transcript
   passes through the existing redaction layer BEFORE disk, and sinks are
   retention-capped (size + age). Append-only files make peeking equal to
   tailing: it works live, post-mortem, and across crashes. The sink is the
   contract that kills the black box; the dashboard is one consumer of it.

4. **`kazi dashboard` — a standalone fleet mode.** A CLI verb boots the web
   endpoint against the shared read-model + registry + sinks (no goal loop in
   that process), localhost-bound by default. Home view: the **starmap** —
   the goal DAG in topological wave bands (reusing the `--explain` frontier
   computation; the ADR-0056 roadmap DAG when present), node states
   landed / converging / claimed / pending / stuck (landed per ADR-0055),
   run/session tags, fleet counts, and a ranked **attention queue** fed by
   the existing detectors plus budget thresholds. Per-goal drill-in: the
   **convergence heatmap** (predicates x iterations from the read-model), an
   iteration scrubber, and **transcript peek** (a live tail of the run's
   transcript sink with tool-call folding).

5. **Single-machine scope now; NATS fan-in is Slice 3.** The shared-SQLite +
   file-sink design deliberately requires zero new infrastructure. When
   Slice 3 arrives, instances additionally publish the same events to
   JetStream and the dashboard subscribes — this dashboard is that slice's
   first real consumer. Cross-node leases remain out of scope (the LeaseTable
   is per-node; NATS is the cross-node answer, unchanged).

## Alternatives considered

- **NATS-first (bus before views).** Rejected for now: a dependency ahead of
  its need (ADR-0007). The registry + sinks give the same observability on
  one machine with zero infra, and nothing in the design blocks the bus
  later — the sink events are the message schema in waiting.
- **An external observability stack (OTel -> Grafana/Loki).** Rejected as the
  primary surface: the load-bearing visualizations (predicate DNA,
  convergence heatmap, wave-band DAG) are domain-specific and are the point.
  The sinks stay plain JSONL precisely so external tooling can consume them
  too; this decision is about the first-party surface, not exclusivity.
- **A TUI (`kazi top`).** Deferred, not rejected: the LiveView assets and
  read-model projections make the web surface the cheap path. A TUI over the
  same registry + sinks is a natural later addition and needs no new data.
- **Registry + polling without transcript sinks.** Rejected: it yields a
  fleet status board but leaves gap 2 (the black box) untouched, and loses
  post-mortem replay — the highest-leverage half of the design.

## Consequences

- The black box closes at both zoom levels: fleet at a glance (starmap +
  attention queue), and per-run "what did the agent actually do" (transcript
  peek), including for dead runs.
- Every run becomes a replayable artifact; the heatmap and scrubber are pure
  renderings of data already persisted.
- Subsumes E20's open observability tail: T20.8 assumed pointing the dev
  dashboard at a shared kazi instance; the registry + shared read-model make
  that assumption obsolete.
- Costs accepted: sink disk usage (bounded by retention caps), heartbeat
  staleness as a liveness heuristic (a hung-but-heartbeating run reads as
  live — the stuck detector, not the registry, catches those), and the
  redaction layer becomes secret-hygiene-critical on a new surface (its
  coverage is pinned by tests in the epic).
- One more documented surface: the verb, the sink format, and the retention
  knobs land with docs in the same changes (ADR-0034).

## Epic
E46 (`docs/plans/E46.md`), UC-061/UC-062.

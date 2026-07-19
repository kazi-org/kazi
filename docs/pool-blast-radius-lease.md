# Per-task blast-radius lease for a pooled run (T20.6, ADR-0026 L3)

This recipe shows how one `/apply --pool` session leases the BLAST RADIUS of its
task before editing, so two pooled sessions never make a SILENT LOGICAL conflict
even when their `/claim` task-locks are disjoint. It is the L3 layer of "kazi
under /apply --pool".

The helper is `Kazi.Pool.Lease` (`lib/kazi/pool/lease.ex`). It is hermetic and
runs on the in-memory lease backend by default (single node); NATS is config-
selected for multi-machine and is NOT required.

## Why a lease BELOW /claim

`/claim` (ADR-0013) is the OUTER coordination: an atomic git-ref lock at
`refs/claims/*` that says which session owns which plan TASK (a `T-`/`S-` id) plus
`R-<slug>` shared-file locks. It is coarse on purpose -- it names a task, not the
code that task will touch.

That coarseness leaves one documented hole (ADR-0026 Context): two DIFFERENT
tasks, with DISJOINT `/claim` locks, can still edit the SAME function and both
rebase-merge clean -- a silent logical conflict that no task-lock and no green CI
catches. The blast-radius lease is the INNER coordination that closes it: each
pooled run leases the actual code paths its task touches, so overlapping radii
serialize and disjoint radii run free.

## The compose-boundary

Claim the TASK first, then lease its BLAST RADIUS. Never invert the order.

```
/claim T-id            # OUTER: this session owns the task (git-ref lock)
  -> Kazi.Pool.Lease   # INNER: this run owns the task's blast-radius code paths
       -> edit         #        (overlapping radii serialize; disjoint run free)
  -> release on terminal (automatic with `with_lease/3`)
release /claim T-id    # OUTER lock released after the PR lands
```

The two layers compose at DIFFERENT granularities (claim = task selection, lease
= blast radius) and neither replaces the other. The claim is held across the whole
task (selection -> PR -> merge); the blast-radius lease is held only across the
edit and is released the moment the run reaches a terminal state.

> The deeper deadlock-safety contract of this boundary (global acquire order,
> TTL liveness, release ordering across BOTH locks) is T20.7. It is documented in
> `docs/pool-claim-lease-deadlock-safety.md` and pinned in code by
> `Kazi.Pool.Compose` (`lib/kazi/pool/compose.ex`): claim FIRST, then lease;
> release lease BEFORE claim; the lease TTL bounds a crashed holder -- a
> consistent global lock order plus TTL liveness, so two sessions each holding a
> claim + a lease cannot deadlock. T20.6 (this recipe) is just the inner lease.

## Usage from a pool session

A session has already taken its `/claim` task-lock. It then wraps the edit in the
blast-radius lease. The `with`-style entry point releases on EVERY exit path
(normal return, raise, throw, exit), so a crash mid-edit never strands the lease.

```elixir
# The task's blast-radius inputs: the goal id(s) plus the evidence terms (changed
# files / target symbols) the radius is expanded from. Same shapes
# `Kazi.Partition.partition/3` accepts.
goals = [{"T-1234", ["lib/kazi/loop.ex", "Kazi.Loop.observe"]}]

lease_acquire_opts = [
  holder: run_id,             # REQUIRED: the run identity (e.g. the kazi apply id)
  workspace: File.cwd!(),     # where the blast radius is expanded
  # backend: Kazi.Coordination.Lease.NATS,  # multi-machine only; omit for single node
  lease_opts: lease_opts      # backend opts (e.g. store: handle) + injected clock
]

result =
  Kazi.Pool.Lease.with_lease(goals, lease_acquire_opts, fn ->
    # === the edit + kazi apply happen here, while the radius is leased ===
    do_the_edit_and_kazi_run()
  end)

case result do
  {:ok, run_result} ->
    # the body ran with the blast radius leased; the lease is already released
    run_result

  {:error, :held, %{key: key}} ->
    # an OVERLAPPING run holds part of this radius -- the body did NOT run.
    # Defer: retry after the holder releases on its terminal state (it will, or
    # the lease TTL reclaims it). Report which radius is contended.
    {:wait, key}
end
```

### Acquire / release without a single block

When the lifecycle is not one lexical block, use `acquire/2` + `release/1`
directly. `acquire/2` is all-or-nothing: a partial acquire rolls back any keys it
already took, so it never strands a lease.

```elixir
case Kazi.Pool.Lease.acquire(goals, holder: run_id, lease_opts: lease_opts) do
  {:ok, held} ->
    try do
      do_work()
    after
      Kazi.Pool.Lease.release(held)   # idempotent; safe to call again
    end

  {:error, :held, %{key: key}} ->
    {:wait, key}
end
```

## What overlaps and what runs free

The helper expands the run's blast radius with `Kazi.Partition.partition/3` (the
union of each goal's surveyed file paths) and leases one key PER path. The
per-path key (not a single hash of the whole radius) is what lets two INDEPENDENT
sessions -- which never see each other's goals -- collide on a shared file:

- two runs that share ANY blast-radius path derive a COMMON key for that path and
  serialize (the second `acquire` gets `{:error, :held, ...}` until the first
  releases on terminal);
- two runs with fully DISJOINT paths derive disjoint key sets and both acquire
  freely (parallel);
- a run with an EMPTY blast radius touches no shared code, leases no keys, and
  never contends.

## Backend selection (single node vs multi-machine)

The backend is injected via `:backend` and defaults to
`Kazi.Coordination.Lease.Memory` -- the correct single-node default (a real,
concurrency-safe in-process lease store, not a stub). For a pool that spans
MACHINES, select the NATS backend (ADR-0004) instead; the lease contract
(`Kazi.Coordination.Lease`) is identical, so only the `:backend` and its
`:lease_opts` change. NATS is never required on one node.

## Hermetic test shape

Every acceptance case for this helper is hermetic: the blast-radius partitioning
injects a `Kazi.Context.GraphSource` double (no real code-review-graph, no MCP, no
network) via `:graph_source`, and the lease contention is asserted against the
in-memory backend on a fixed injected clock (`now_ms:`), with NO NATS. See
`test/kazi/pool/lease_test.exs`.

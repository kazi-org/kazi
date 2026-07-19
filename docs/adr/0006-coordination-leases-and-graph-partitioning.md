# ADR 0006: Coordination by resource leases + graph-aware partitioning

- Status: Accepted
- Date: 2026-06-21
- Depends on: ADR-0004 (JetStream)

## Context

Locking a *task* is mutual exclusion on identity: it stops two agents doing the
same task, but not two agents doing different tasks that edit the same files —
the real source of merge conflicts. Task locks are also a poll-able mailbox, not
a live channel, so agents cannot negotiate. The prior git-ref claim primitive had
both limits (and no TTL). The maintainer's repos already run
`code-review-graph`, which can compute a change's blast/impact radius.

## Decision

Coordinate on **resources, not identities**:

1. **Blast-radius leases.** Before editing, an agent leases the set of
   modules/files it will touch. Leases live in JetStream KV `leases` (CAS by
   revision, per-key TTL). Disjoint lease-sets run concurrently; overlapping ones
   serialize or queue.
2. **Graph-aware partitioning.** A task's lease-set is computed from
   `code-review-graph`'s impact radius. kazi assigns parallel agents
   *non-overlapping* blast radii by construction — conflict-free parallelism, not
   just collision detection after the fact.
3. **Live awareness.** Presence heartbeats and intent announcements flow over
   JetStream `presence.*` / `intent.*` subjects.
4. **Merge as reconcile.** Parallel fixers work in isolated git worktrees;
   integration is a reconcile sub-step (merge-safety protocol), shrunk — not
   eliminated — by disjoint leases.

## Consequences

- The "different task, same file" conflict is prevented at assignment time.
- A crashed agent's lease auto-expires via KV TTL — no manual prune.
- Coordination quality depends on graph freshness; kazi must check/refresh the
  graph before partitioning (a stale graph silently under-partitions).
- Where the graph does not see edges (reflection, codegen, string dispatch),
  partitioning can overlap; the merge-reconcile step is the backstop, and such
  cases should widen the lease conservatively.

## Alternatives rejected

- **Task-identity locks only** (git refs / prior `/claim`) — does not prevent
  file collisions; no live channel; no TTL.
- **Optimistic, conflict-on-merge only** — wastes work; the graph lets us avoid
  most conflicts up front for near-free.
- **Whole-repo lock per agent** — correct but kills parallelism, the entire point.

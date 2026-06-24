# ADR 0004: Coordination substrate — NATS JetStream

- Status: Accepted
- Date: 2026-06-21

## Context

kazi coordinates concurrent agents across one or many machines (laptop, a GPU
host, cloud). It needs: atomic compare-and-set for leases, automatic expiry of a
crashed agent's lease, a live pub/sub channel, and a durable event log — and it
must be the *final* substrate (no "start with X, migrate to Y" — an explicit
requirement). Git refs (the prior claim primitive) provide CAS but no TTL, no
live channel, and high latency. The maintainer already runs NATS JetStream for
an existing cluster.

## Decision

**NATS JetStream is the single source of truth for coordination**, used the same
way on one machine or many (single-node points at a local/embedded NATS; the
cluster simply degenerates to one node):

- **KV bucket `leases`** — blast-radius leases; atomic CAS by revision; **per-key
  TTL** so a dead agent's lease auto-expires (eliminates manual prune).
- **KV bucket `goals`** — declared desired state (predicate specs).
- **Stream `kazi.events`** — append-only evidence/iteration log; durable and
  replayable; the source for the SQLite read-model.
- **Subjects `presence.*`, `intent.*`** — ephemeral live chatter (heartbeats,
  intent announcements).

Git remains the source of truth for code; JetStream never stores code.

## Consequences

- Lease CAS + TTL fixes two prior pains at once: collisions and stale-lock
  pruning.
- A real live channel (git could never provide one) enables presence and intent.
- Cross-machine coordination is free; no bespoke clustering.
- NATS is always in the path, even single-machine. Acceptable: already operated
  elsewhere, and the alternative (BEAM-native clustering over real networks) is
  the finicky path.

## Alternatives rejected

- **Git refs** — no TTL, no live channel, push latency; kept only as the legacy
  primitive in the skills repo, not for kazi.
- **BEAM-native (Horde + PubSub + Mnesia)** — zero external infra but
  cross-machine over NAT is fragile and Mnesia has sharp edges.
- **Postgres LISTEN/NOTIFY + advisory locks** — viable, but heavier to operate
  and not already running; no TTL-native leases.
- **Redis** — another piece of infra with no advantage over JetStream here.

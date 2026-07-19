# ADR 0067: Session coordination bus -- operator sessions become first-class participants on the JetStream substrate

## Status
Accepted

## Date
2026-07-10

## Context

Operators routinely run several concurrent driving sessions (Claude Code or
any harness session invoking kazi) per project, and several projects per
machine -- and the ADR-0065 fleet direction multiplies the number of kazi
processes each of those sessions supervises. Today those sessions cannot talk
to each other. Four concrete coordination gaps, each observed as a real
incident:

1. **Presence.** "Is the session converging goal X still alive, or abandoned?"
   is unanswerable without a human cross-checking process tables. The run
   registry (ADR-0057) records runs, not the sessions driving them.
2. **Intent broadcast.** A release window is a machine-wide event: the first
   launch of a new binary used to delete payload dirs under live runs
   (issue #1018), and mixed-version writers deadlocked the shared read-model
   (issue #1019). No session could warn the others that an upgrade was in
   flight.
3. **Shared facts.** "main is red; it's the known flake; re-run greens it" is
   rediscovered by every session independently -- the diagnosis is paid for N
   times.
4. **Directed messages.** Handoffs ("task T is yours", "you own that module, I
   found a bug in it") route through the human or not at all.

Three prior decisions shape the solution space:

- **ADR-0004** already designated NATS JetStream the coordination substrate,
  explicitly reserving `presence.*` / `intent.*` subjects for "ephemeral live
  chatter (heartbeats, intent announcements)", and ADR-0005 gave coordination
  its own authoritative layer. But nothing has ever activated it: everything
  shipped so far is deliberately single-node and NATS-free (ADR-0065 restates
  this; the lease table is per-BEAM-node). The substrate exists on paper with
  zero live traffic.
- **kazi already models session identity**: `--session-name`, the
  `KAZI_SESSION_NAME` env var, and `CLAUDE_CODE_SESSION_ID` auto-detection are
  recorded on run-registry rows and rendered on the starmap SESSIONS rail.
  Sessions are visible in kazi today -- they are just mute.
- **The readers are LLM sessions.** Every message a session reads occupies
  context-window tokens. The scarce resource is attention, not bandwidth:
  message volume will be high (fleets emit constantly), so token cost must be
  decoupled from message volume *by design*, not by client discipline.

## Decision

**kazi grows a session coordination bus, hosted by a new `kazi daemon`, on the
ADR-0004 JetStream substrate. This is the decision that activates Slice 3's
NATS dependency** (permitted since ADR-0003/0007; deferred until something
needed it -- this needs it).

1. **`kazi daemon`.** A long-lived per-machine process that supervises a local
   `nats-server` (or connects to an external one via config) and owns the bus
   streams/buckets. Everything else in this ADR degrades gracefully when the
   daemon is not running: bus surfaces report "no daemon" cleanly and no-op.
   **Convergence never depends on the bus** -- a goal must converge
   identically with the daemon down. The bus is coordination infrastructure,
   not a step in the reconcile loop.

2. **Participants: operator sessions AND kazi runs.** Identity reuses the
   existing session-name resolution chain unchanged. Runs mirror their
   lifecycle onto the bus (started, terminal verdict) so sessions observe
   fleet state without polling the read-model.

3. **Four primitives, each mapped to the JetStream feature built for it:**

   | Primitive | Mechanism | Semantics |
   |---|---|---|
   | presence | KV bucket, per-key TTL | heartbeat = KV put; liveness = key exists; stale sessions expire with no reaper |
   | fact | last-value-per-subject retention | "current state of topic", deduped -- publishing the same fact twice is idempotent |
   | event / intent | limits-retention stream (age-bounded, ~24h) | the operational "now": release windows, upgrades, wave boundaries |
   | directed message | subject per recipient + one durable consumer per session | the durable consumer IS the read cursor: delta reads, replay, backpressure for free |

4. **Subject taxonomy designed for growth from day one:**
   `bus.<scope>.<kind>.<qualifier>` where scope is `machine` (cross-project:
   release windows, disk pressure) or a project id derived from the canonical
   repo root (worktrees share their base repo's scope). One machine today, a
   cluster later, with no protocol change -- the same property ADR-0004 bought
   for leases.

5. **Token economy is enforced server-side, in the daemon.** `kazi bus read`
   returns a *digest*, not a transcript: counts and last-values for bulk
   traffic, verbatim text only for items addressed to the reader or marked
   `sev: interrupt`. A hard per-message size cap (~1 KB) forces one-line
   discipline at the producer. Reading a thousand-message backlog costs the
   same context as reading forty lines. This is the reason a daemon (rather
   than a shared file) is load-bearing: only a server can aggregate before the
   tokens are spent.

6. **Surfaces.** `kazi bus post|read|who|tell` CLI verbs (hook-friendly,
   `--json`) and matching `kazi mcp` tools (ADR-0044). Delivery into a session
   is the harness's own hook mechanism calling `kazi bus read` on turn
   boundaries; that recipe ships as documentation (AGENTS.md / docs), because
   kazi drives harnesses and does not reach into them (ADR-0001/0008
   boundary).

7. **Messages are advisory, provenance-stamped input.** Every message carries
   its origin (session, machine, timestamp). A reading session weighs bus
   content as background input; it is never a command channel that overrides
   the operator. This is stated in the surfaces' own help text because
   agent-written messages injected into other agents' contexts are a mild
   prompt-injection surface and deserve an explicit contract.

8. **Bus is not memory.** Events age out; the bus carries operational "now".
   Durable knowledge keeps routing through the ADR-0036/0060-0063 paths
   (lore/devlog/ADRs, gated memory writes). Nothing on the bus is
   authoritative for anything (ADR-0005: JetStream is authoritative for
   coordination -- the bus is coordination).

## Consequences

- The four gaps close mechanically: presence is a KV lookup, release windows
  become a broadcast every session hears, facts are paid for once, handoffs
  have a channel. Issues #1018/#1019's *blast radius* (sessions harming each
  other unknowingly) gets an awareness layer even where the root causes are
  separately fixed.
- ADR-0004's substrate finally carries real traffic, and the known cross-node
  lease gap (lease table is per-BEAM-node) gains its intended transport for a
  later ADR to use. Cross-machine coordination becomes a config change, not a
  redesign.
- New operational surface: a daemon plus a supervised `nats-server`
  (single small binary). Mitigated by graceful degradation (point 1) -- kazi
  without the daemon behaves exactly as today.
- ADR-0068 (proposed alongside) builds on the same daemon to fix #1019
  structurally; the two ADRs share the daemon but are independently
  acceptable.

## Non-goals

- **No agent-org semantics.** No delegation hierarchies, roles, or org charts
  on the bus -- ADR-0048's exclusion stands. The bus coordinates peers working
  a shared plan; it does not manage them.
- **Not a task queue and not a lock service.** Goals (ADR-0002) define work;
  leases (ADR-0006) provide mutual exclusion. A bus message never assigns or
  claims work; it can only *point* at those mechanisms.
- **Not a human chat UI.** The starmap may render bus traffic; kazi does not
  grow a messaging app.

## Alternatives rejected

- **Filesystem blackboard (append-only jsonl + per-session cursors + hook
  injection).** Zero infrastructure and workable at low volume, but it fails
  the stated scale requirement structurally: no server-side aggregation means
  token cost grows linearly with message volume; no TTL or last-value
  semantics without a reaper; delivery depends on every client's discipline.
  Rejected as the end-state; its delivery-via-hooks idea is retained (point 6).
- **Git refs as mailboxes.** Already rejected by ADR-0004 for coordination
  (no TTL, no live channel, push latency); doubly wrong for chatty traffic.
- **BEAM-native pub/sub inside each CLI process (no daemon).** No durability,
  no single aggregation point (so no digests), and cross-machine over real
  networks is the fragile path ADR-0004 already declined.
- **A sibling standalone tool outside kazi.** The ADR-0060 sibling-tool
  argument applies unchanged: an external coordinator cannot see kazi's runs,
  leases, or session identities without a seam that fails silently, and kazi
  already owns parallel-work coordination (ADR-0027/0065). Session
  coordination is the same concern one level up.

## Update: cross-machine connect-mode implemented

The Consequences section above states cross-machine coordination "becomes a
config change, not a redesign" — that connect-mode (`kazi daemon start
--nats-host <host>`, alongside a `--nats-token` shared-auth option) is now
implemented; see `docs/session-bus.md` ("Cross-machine setup") for the
two-role setup and the PR that landed it.

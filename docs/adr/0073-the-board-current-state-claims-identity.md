# ADR 0073: Teams need a board — a current-state projection with claim visibility and stable identity

## Status
Accepted

## Date
2026-07-16

## Refines / supersedes

**Extends** ADR-0067 rather than superseding a decision point. It revisits one
**alternative** ADR-0067 rejected — the filesystem blackboard — and splits the
verdict: the rejection of the *implementation* stands and is reaffirmed; the
*interaction model* it discarded along with it is readmitted, on the substrate
ADR-0067 already chose.

Reaffirmed unchanged: point 3's primitive→mechanism table (this ADR adds no new
primitive — it renders one kazi already provisions), point 8 ("bus is not
memory"), and both operative non-goals — **"Not a task queue and not a lock
service"** and **"Not a human chat UI"**. Point 2's participants and the
existing session-name resolution chain are extended, not replaced.

## Context

### The teams already left

The strongest evidence available about this bus is that its users tried it and
quit. A team lead announced on the bus itself that coordination "has MOVED to
the file blackboard ... (append-only log; re-read at every turn boundary)", and
after the blocking bug was fixed and announced fixed, the team did not come
back: assignments "remain in the durable file". Two separate project teams
independently converged on the same shape — an append-only markdown file under
the harness config directory, re-read every turn.

They rebuilt, by hand, the precise alternative ADR-0067 rejected. That is not a
failure of discipline; it is a design signal, and it is worth reading exactly.

**A stream answers "what changed since I last looked". A team needs "what is
true right now"** — who is here, who owns what, what is claimed, what is free.
`read`/`peek` render only *pending* stream messages; a session that reads gets a
delta and no state. The board they needed does not exist as a surface.

It does exist in the substrate. ADR-0067 point 3 already provisions `fact` as
**last-value-per-subject retention** — "current state of topic, deduped" —
which *is* a board. kazi has been storing the board since the bus shipped and
has never had a verb that renders it.

And the fallback cost them the one thing the bus uniquely provides: the file
lives under a single machine's home directory. It does not exist on the second
machine. By leaving the bus for files, a team whose sessions span two machines
made cross-machine coordination structurally impossible — while the daemon sat
up, connected, and carrying their presence correctly the whole time.

### Ownership is invisible, so work duplicates

Duplicate work on this bus is not a messaging failure. It is a lock-*visibility*
failure. Observed in one evening's traffic: two idle sessions on the same branch
both broadcasting for an assignment; a session that had been declared closed
picking up the work stream of the session that replaced it; and a lead
hand-maintaining ownership in free text — "item (1) is CLAIMED (owner: ...) —
do not pick it up" — then re-broadcasting corrections as the list changed.

Claims are real and authoritative: `/claim` takes atomic git-ref locks at
`refs/claims/*`, and ADR-0006 makes leases the mutual-exclusion mechanism. The
bus simply never hears about them. So a human or an LLM does a lock service's
bookkeeping by hand, in prose, on a channel with no state — and gets it wrong,
because prose is not a projection.

ADR-0067's non-goal is explicit and correct: "A bus message never assigns or
claims work; **it can only point at those mechanisms**." Today it does not even
point.

### Identity is not addressable

Presence rows carry raw session UUIDs. Where session-name detection fails, the
row is an `os-<pid>` fallback that changes with every process — four such rows
are live right now, permanently unaddressable and re-registering as new
"sessions". Zero sessions have ever joined a team (`bus join`), so `bus who
--team` and `bus tell @<team>` have no roster to work with.

The workaround is visible in the traffic: sessions broadcast "I am
<nickname>" as free-text facts, publish corrections when a name changes, and
address each other with `@<nickname>` inside message bodies — because `tell`
requires an id nobody knows and no verb assigns a name. Directed messaging, the
fourth gap ADR-0067 set out to close, is unusable in practice for want of a
name.

### The operator cannot see the team either

The dashboard's lease map renders **"Presence — No instances present"** while a
dozen sessions are live on the bus. Its default source projects the in-memory,
per-BEAM-node lease table, whose own moduledoc states presence is always empty
because a native run announces none; bus presence lives in the daemon's KV
bucket and is reachable only through the transport-backed source, which nothing
configures. The one surface where a human could see the whole team at a glance
is wired to the one source that structurally cannot show it.

## Decision

**The bus grows a board: a durable, cheap, cursor-free projection of current
team state. Everything that constitutes that state — facts, roster, ownership,
identity — projects onto it, and both the CLI and the dashboard render it.**

1. **`kazi bus board [--scope <machine|project>]`** renders current state:
   last-value `fact` per topic, the live roster (with names and teams), and
   claim ownership. It is idempotent, cursor-free, and consumes nothing — a
   session may read it every turn without draining anything a `read` was
   counting on. It is bounded by ADR-0072's digest rules. This is what the
   ADR-0076 session-start hook injects, and it is what replaces the hand-rolled
   markdown blackboards — with the cross-machine property those files gave up.

2. **Claims stay authoritative where they are, and the board reads them at
   source.** Leases and `/claim` git-refs remain the mutual-exclusion
   mechanism (ADR-0006); the bus does not arbitrate, does not grant, and
   cannot deny. The board's ownership section is a **direct projection of
   `refs/claims/*`** read from the shared remote: the claim primitive already
   pushes every claim to origin, and the claim commit already carries owner,
   host, and timestamp in its message — the refs are already cross-machine and
   already self-describing. Reading them at source means there is **no copy to
   drift, no staleness class, and no daemon anywhere in the claim path**; when
   the remote is unreachable the board says so in one honest line rather than
   rendering possibly-stale ownership.

   This is also the only design kazi can actually ship: the claim primitive
   lives in the operator's global tooling, **outside this repository's
   delivery**. A design whose correctness requires editing that tooling — for
   example, "taking a claim auto-posts a fact" — repeats ADR-0067 point 6's
   failure exactly: correctness delegated to a recipe kazi cannot install. An
   optional, documented one-liner (a best-effort `bus post` a claim wrapper
   MAY add) exists so that turn-boundary **digests** can announce "claimed T"
   as an event — but the board never renders ownership from it, and nothing is
   less correct where it is absent.

3. **Stable, addressable identity.** `kazi bus name <nickname>` assigns a
   durable name for the session, carried on presence and rendered by `who`,
   `tell`, and the board; `tell` resolves a nickname, a team, or a session id.
   The `os-<pid>` fallback is replaced by an id stable across the session's
   processes, so a session can never fragment into ghost rows. The session-name
   resolution chain (ADR-0067 point 2) gains a durable layer rather than being
   replaced.

4. **The dashboard renders the board.** When a daemon is up, the operator
   surface defaults to the transport-backed coordination source, so presence,
   roster, and claims appear where a human already looks. The read-only
   projection contract (ADR-0011) is unchanged — the dashboard observes and
   never writes. Without a daemon it falls back to today's native source and
   renders exactly as it does now.

5. **The board is state, not history, and not memory.** It holds what is
   currently true; ADR-0067 point 8 stands — events age out, and durable
   knowledge keeps routing through the ADR-0036 tiers (lore/devlog/ADRs). The
   board is not a log to be mined, and reading it is never a substitute for the
   plan (ADR-0002 goals remain the definition of work).

## Consequences

- The siloing and duplicate work close mechanically rather than by exhortation:
  a session that starts sees who is here, what they own, and what is free —
  before it picks anything up.
- The markdown blackboards lose their reason to exist, and cross-machine teams
  stop paying for a machine-local fallback.
- `fact`'s last-value retention finally does the job point 3 provisioned it for.
  No new primitive, no new stream, no new storage decision.
- Claims and the bus stay fully decoupled: a claim succeeds, is visible, and
  expires by exactly the mechanism it does today, daemon or no daemon. The
  cost moves to the board instead — its ownership section needs the repo
  remote, so rendering it takes a network round-trip and must degrade to an
  honest "claims unavailable" line offline. That trade is deliberate: a
  slightly slower board beats a second copy of ownership truth.
- The dashboard gains a real dependency on the daemon for its presence rail —
  behind a fallback, so a native run is unaffected.
- Identity becomes something an operator can rely on when addressing sessions,
  which makes `tell` and teams usable for the first time.

## Non-goals

- **Still not a lock service and still not a task queue** (ADR-0067 non-goal,
  reaffirmed). The board *shows* claims; it does not grant, arbitrate, expire,
  or assign them. Any design pressure to let the board decide ownership is a
  signal to fix the lease layer instead.
- **Still not a chat UI** (ADR-0067 non-goal, reaffirmed). The board renders
  state, not conversation.
- **Not an agent org chart.** ADR-0048's exclusion of delegation hierarchies and
  roles stands; a roster of peers with names and claims is not a hierarchy, and
  "lead" is an operator convention, not a bus concept.
- **Not durable knowledge.** See point 5.

## Alternatives rejected

- **Bless the markdown blackboards** (make them kazi's model, or teach kazi to
  read them). ADR-0067's original rejection stands unchanged and is what the
  teams' own experience confirmed: no server-side aggregation (so token cost
  grows with the file), no TTL (so stale ownership is indistinguishable from
  live), and delivery by client discipline. Their fatal flaw here is
  machine-locality — they cannot see a second machine, which is the whole reason
  the bus exists.
- **Move claims onto the bus** (bus as the lock service). Rejected by ADR-0067's
  non-goal and by ADR-0006. It would also make the daemon load-bearing for
  claiming, breaking point 1. Broadcasting a lock is not owning it.
- **Auto-posted claim facts as the board's ownership source** (the shape this
  ADR's first draft proposed). Three strikes: it creates a second copy of
  ownership truth that can drift from the refs and needs its own staleness
  reconciliation; it makes claim visibility depend on the daemon being up at
  claim time; and above all it is unshippable — the posting would have to live
  in claim tooling outside kazi's delivery, which is ADR-0067 point 6's
  documentation-as-mechanism failure wearing a new coat. Reading the refs at
  source has none of these and was available all along.
- **A `bus history` / full-log verb instead of a projection.** Gives a session
  the raw stream and asks it to derive current state itself — every reader
  re-implements the projection, pays for the whole log, and derives it
  differently. The projection is the product.
- **Leave the dashboard as-is and read the board from the CLI.** Keeps a human
  surface that says "No instances present" while a dozen sessions work, which
  is worse than having no rail at all: it reads as an authoritative "nobody is
  here."

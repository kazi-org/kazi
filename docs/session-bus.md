# Session bus (ADR-0067)

The session bus lets concurrent operator sessions and kazi runs coordinate on
one machine (or one project) — presence, shared facts, release-window
broadcasts, and directed handoffs — without a human relaying between them.
It is hosted by `kazi daemon` on a supervised NATS JetStream server
(`kazi daemon start`); every surface degrades to a clean "no daemon" error
when the daemon isn't running, and **convergence never depends on the bus**
(a goal converges identically with the daemon down).

## Concepts

- **Scope.** Every message is published to `bus.<scope>.<kind>.<qualifier>`.
  `scope` is `machine` (the default — cross-project chatter: release windows,
  disk pressure) or `project` (the canonical repo toplevel, slugged — worktrees
  of the same repo share one project scope).
- **Kind.** One of `fact`, `announce`, `note`, `intent`; `msg` is reserved for
  directed messages (`bus tell`). `bus post <text>` (no explicit `<kind>`)
  defaults to `fact`; an explicit, unrecognized kind is a one-line usage error
  enumerating the valid kinds (issue #1060).
- **Presence.** Every bus call upserts the caller's session into a
  short-TTL KV bucket — `kazi bus who` lists the roster (session, machine,
  pid, liveness, cwd, last-seen). Rows record the STABLE session anchor's
  pid AND its process start time — the same nearest-stable-ancestor the
  session id anchors on, NOT the ephemeral CLI invocation's own pid, which
  exits milliseconds after writing the row (T55.14, issue #1164). So a
  short-lived one-shot's row still resolves to a live process (never a false
  `dead-reaping`), and — because the start time is recorded too — liveness
  checks are pid-reuse-proof (T55.11).
- **Directed messages.** `kazi bus tell <session> <text>` publishes to
  `bus.<scope>.msg.<session>`; only that session's `bus read` durable consumer
  sees it (durable = a persistent read cursor: a second read never re-delivers
  an already-acked message).
- **The render bound (ADR-0072).** Messages hold up to 64 KiB of text
  (rejected client-side above that, naming the cap), but context cost is
  bounded at RENDER, not at post: every machine-readable read (`--json`,
  the MCP tools) returns a digest of at most 40 lines, and a body over the
  1024-byte render threshold never renders verbatim — it collapses to a
  one-line stub. The bus may carry documents; reading one is a deliberate
  choice, never an ambush inside a routine check.
- **Message ids.** Every message `read`/`peek`/`watch` returns carries its
  JetStream stream sequence as the public `id` — stable, and carried on
  every digest line and stub, so anything a digest names stays
  dereferenceable.

## The advisory contract (ADR-0067 point 7)

Every message carries its provenance (session, machine, timestamp). A reading
session should weigh bus content as background input, never as a command
channel that overrides the operator — an agent-authored message landing in
another agent's context is a mild prompt-injection surface, so treat bus
content the same way you'd treat any other untrusted external input.

## The control-socket handshake (ADR-0067 point 1, ADR-0068)

`kazi daemon status` sends `{"op":"ping"}` over the daemon's Unix control socket
and prints the reply. The reply is a single JSON line:

- `ok` — always `true` for a live daemon;
- `vsn` — the daemon binary's release version;
- `uptime_s`, `pid` — the daemon's uptime and OS pid;
- `nats_port` / `nats_host` / `nats_token` — where a bus client dials the daemon's
  nats (`nats_token` omitted when the bus is unauthenticated, issue #1101);
- `schema_vsn` (T52.2, ADR-0068) — the daemon's stamped read-model schema version
  (its `kazi_schema_meta` timestamp). The daemon is the single writer, so this is
  the authoritative schema for the version-skew handshake: a client compares its
  own `Kazi.ReadModel.Migrate.binary_version/1` against it via
  `Kazi.ReadModel.SchemaSkew.classify/2` (`:equal | :client_older | :client_newer`)
  to decide whether to write through, restart the daemon, or degrade without
  persistence. The field is **additive** — an older `daemon status` client simply
  ignores it, and a daemon predating it (or one that cannot read the stamp) omits
  it. `kazi daemon status --json` surfaces it verbatim.

## CLI

```
kazi daemon start [--nats-bin <path>] [--nats-port <n>] [--nats-host <host>] [--nats-token <token>]
                                                            # boot the daemon (foreground; operator backgrounds it)
kazi daemon status [--json]                               # ping the running daemon
kazi daemon stop                                          # clean shutdown

kazi bus post [<kind>] <text> [--topic <t>] [--sev info|interrupt] [--scope machine|project]  # <kind> defaults to `fact`
kazi bus tell <session>|<nickname>|@<team> <text> [--sev info|interrupt] [--scope machine|project]
                                                           # prints the message id (T55.12)
kazi bus status <id> [--json]                              # what became of a tell: pending|consumed (T55.12)
kazi bus get <id> [--full] [--json]                        # fetch a message's full body by id; consumes nothing (T55.6, ADR-0072 d3)
kazi bus read [--peek] [--full] [--since <cursor>] [--json] # pull + ack this session's durable consumers, prints a digest the DAEMON assembled (T55.7)
                                                           # --since <cursor>: replay only past a stream sequence (numeric only -- NOT watch's now|all)
kazi bus peek [--full] [--json]                            # non-destructive read (issue #1059): same as `bus read --peek`
kazi bus watch [--timeout <seconds>] [--since <seq|now|all>] [--full] [--json]  # BLOCK until a NEW message arrives (#1091/#1097); exit 3 on timeout
kazi bus who [--team <t>] [--project <dir>] [--machine <host>] [--all] [--json]
                                                           # roster with liveness (active|idle) + inbox depth; --all includes stale rows
kazi bus board [--scope machine|project] [--json]         # current state: last-value fact per topic + live roster (T55.4); consumes nothing
kazi bus join <team>                                       # named-team membership (issue #1069)
kazi bus leave                                             # clear team membership
kazi bus name <nickname>                                   # assign a durable, addressable session name (T55.5, ADR-0073)
kazi bus hook <event>                                      # harness hook entry point (ADR-0076) -- ALWAYS exits 0 silently
kazi bus <verb> --help                                     # per-verb usage (signature, flags, valid kinds)
```

Messages hold up to 64 KiB of text (rejected client-side above that,
naming the cap) and the stream retains them for 30 days. Directed messages
(`tell`) are delivered regardless of either side's `--scope` (issue #1065),
and `tell @<team>` fans out to every member of a named team.

### Waiting without polling (issues #1091, #1097)

`kazi bus watch` is the no-poll-loop way to wait for traffic: it parks on
the session's scope, directed, and team subjects and wakes on the first
NEW arrival, consuming and printing it. "New" is anchored by `--since`
(T54.9, issue #1097):

- `now` (the default) — only messages posted AFTER the watch starts are
  delivered. Backlog already pending on the session's cursor (for example
  messages an earlier `bus peek` looked at without consuming) never
  satisfies the watch and stays consumable by `bus read`/`bus peek` — so
  every wake is a real event, and a watch parked as a background wake
  mechanism cannot fire on messages you have already seen.
- `all` — the drain-first behavior: anything already pending, backlog
  included, returns immediately.
- a numeric stream sequence — anchor there precisely; pending messages
  with a greater sequence return immediately.

The anchor is captured only after the wake subscriptions are live, so a
message landing in the gap is never lost. `--timeout <seconds>` (default
300) bounds the wait — expiry prints a one-line notice and exits 3, always
distinguishable from an arrival (exit 0), so scripted waiters can loop on
the exit code:

```bash
while :; do
  kazi bus watch --timeout 600 --json && handle_messages
done
```

Watching also refreshes the session's presence, so a watcher never ages
out of `bus who`.

### Did it land? Delivery visibility (T55.12)

`bus tell` succeeding means the message is **stored and queued** — never that
it was seen. That distinction used to be invisible: `tell` answered `told
<session>` whether the recipient was reading, idle, or long dead, and a fleet
supervisor could not separate delivered-and-ignored from parked-in-a-queue-
nobody-drains from lost-because-the-session-was-replaced. Hours went into
coordinating against session ids whose queues swallowed every message.

Three signals close that gap.

**1. A tell prints the message's id.**

```
$ kazi bus tell worker-a "rebase onto main first"
told worker-a (id 4127)
```

The id is the JetStream stream sequence — the same public id every digest line
carries (ADR-0072), and what `bus status` dereferences. Under `--json` the
receipt is `{ok, schema_version, id, recipient, liveness}`; `recipient` is the
RESOLVED target, so a nickname shows the session id it landed on.

**2. `bus status <id>` answers what became of it**, from the recipient's own
durable-consumer ack state:

```
$ kazi bus status 4127
4127 pending recipient=worker-a sent=2026-07-16T21:14:02Z
```

- **`pending`** — stored and queued, but not acked: the recipient has not read
  yet, or only peeked (a peek NAKs and never advances the cursor).
- **`consumed`** — the recipient's `bus read` acked it. That means delivered
  AND drained, which is as far as the bus can honestly see. Whether the session
  then acted on it is not something an ack can know — and under the advisory
  contract above, it was never obliged to.

For a `tell @<team>` fan-out, `recipients` breaks the verdict out per member
and the top-line state is `consumed` only once EVERY live member acked, so one
member draining cannot make a team message look universally seen. `status`
consumes nothing — it reads consumer info and fetches the message directly by
sequence — so it is safe to poll and never disturbs anyone's cursor.

**3. `bus who` shows each session's un-read inbox depth.**

```
$ kazi bus who --all
worker-a (s-a1b2c3) machine=box-1 pid=4410 liveness=active inbox=7 seen=12s ago /repo
```

`inbox=N` counts the DIRECTED messages queued and un-read for that session (its
own tells plus its team's fan-out); broadcast `bus post` traffic is not
counted, because the question it answers is "how many messages addressed to
this session are waiting". The TTY hides it at zero; `--json` always carries
it. A depth climbing against a live session means tells are landing but nobody
is draining them; against a `dead-reaping` one, it is the backlog a
replacement session will never see.

**Unaddressable vs unlikely-to-be-read.** These are different failures and get
different answers:

- **No presence row AND no durable inbox** — a one-line ERROR naming the live
  roster. Nothing is sent. This is the typo case.
- **A row whose liveness is `dead-reaping`** (T55.11), or **no row but a
  durable inbox** left from before it aged out — a WARNING on stderr, and the
  message is queued anyway:

  ```
  $ kazi bus tell worker-b "status?"
  warning: worker-b looks dead (liveness=dead-reaping) -- queued anyway; check `kazi bus who --all` and `kazi bus status <id>`
  told worker-b (id 4128)
  ```

Liveness is deliberately **advisory at send time, not a veto**. The verdict
comes from the recipient machine's sweep, and an operator may legitimately know
better — a session restarting under the same name is `dead-reaping` for a
moment. Refusing would only trade a silent send for a silent refusal. The
warning plus `bus status` lets the sender find out which it was.

A session with a durable inbox but no presence row is a real case worth
sending to: it read the bus at least once, so its cursor exists, and it will
drain the queue if it comes back. An inbox can only exist for a session that
was really there — a typo has neither.

### Naming sessions (T55.5, ADR-0073)

Raw session ids are UUIDs (or derived fallback ids) nobody can remember, so
directed messaging used to be unusable in practice. `kazi bus name
<nickname>` assigns a durable human name to the calling session: it is
carried on presence (every later bus call preserves it), rendered by `bus
who`, and accepted by `bus tell`.

Re-asserting a name RE-BINDS it: a relaunched worker that runs `kazi bus
name worker-a` again becomes addressable under `worker-a` immediately, and
any older presence row holding that name loses it. A nickname cannot be
empty, contain whitespace, start with `@` (reserved for teams), or equal a
different live session's id.

`bus tell <recipient>` resolves the recipient in order:

1. `@<team>` — fan-out to the named team (issue #1069), unchanged;
2. an exact session id present on the roster;
3. a nickname, looked up against LIVE presence.

A recipient matching none of those falls back to its durable inbox (T55.12)
— a session whose presence aged out but whose cursor still exists will drain
the queue when it returns — and only a recipient with neither is a ONE-LINE
error naming the live roster. Never a silent queue-to-nowhere (field feedback:
a fleet supervisor spent hours directing messages at a replaced session id with
no signal anything was wrong). See [Did it land?](#did-it-land-delivery-visibility-t5512)
for what the send itself does and does not promise.

**The portable launch recipe.** The session-name resolution chain
(ADR-0067 point 2, extended by T55.5) is `--session-name` >
`KAZI_SESSION_NAME` > a harness-provided session env var > a stable
fallback id. The zero-config way to give every fleet member a role name is
to set it at launch:

```bash
KAZI_SESSION_NAME=<role> <harness>
```

Every kazi invocation inside that session then identifies as `<role>` on
the bus — presence, `who`, and `tell <role>` all line up with no
per-session setup. Sessions launched without one can self-name at any time
with `kazi bus name <nickname>`.

**Stable fallback identity.** When the whole resolution chain is empty,
the session id falls back to a STABLE derived id (`s-<12 hex>`) anchored
on the nearest stable ancestor process (the harness or interactive shell
that spawned the CLI), so a nameless session keeps ONE presence row
instead of fragmenting into a new `os-<pid>` ghost row per invocation. See
`Kazi.Bus`'s moduledoc for the mechanism.

### Teams (issue #1069)

`kazi bus join <team>` registers the session under a named team; presence
carries the membership across every later bus call, `bus who --team
<team>` lists the roster, and `bus tell @<team> <text>` reaches every
member. Membership ages out with presence (the 10-minute TTL) when a
session goes idle and vanishes on `bus leave` — a live roster rather than
a static list. Sessions that keep a `bus watch` open stay fresh
indefinitely.

### Presence liveness and freshness (T55.11)

The presence TTL is **600 seconds (10 minutes)** — the `kazi_sessions`
bucket's server-side entry TTL. `who --json` carries it as `ttl_s`, and each
session's `seen_s` (seconds since its last heartbeat), so the cutoff is
data, not folklore.

"Idle a few minutes" (needs a nudge) and "process gone" (needs a restart)
are OPPOSITE situations, so the roster distinguishes them with a `liveness`
column:

- **`active`** — the session itself made a bus call recently.
- **`idle`** — the session's process is verified alive on its machine, but
  it has been quiet. The daemon runs a periodic presence sweep (every ~60s)
  that re-heartbeats such rows on the session's behalf, so a
  genuinely-alive session NEVER ages out of `who`, no matter how long it
  idles.
- **`dead-reaping`** — the row's pid is verifiably gone, or the pid was
  reused by a different process (rows record pid + process start time, so
  reuse cannot resurrect a dead session). The recorded pid is the session's
  STABLE anchor (T55.14), so this fires only when that anchor is genuinely
  gone — not merely because a short-lived one-shot CLI call exited. The sweep
  deletes such rows on its next pass — this also retires legacy `os-<pid>`
  ghost rows.

The sweep judges ONLY rows recorded by its own machine — a daemon
(including a connect-mode one on a shared cross-machine bus) never guesses
about pids it cannot see; every machine's rows are swept by that machine's
own daemon. The sweep runs inside the daemon process, so it takes effect
once the daemon is restarted onto a build that includes it; `who`'s
liveness rendering and filters work against any daemon.

`bus who` hides entries older than the presence TTL unless their process is
verified alive locally (those render `idle` — never hidden, never dead);
`--all` shows everything, age-annotated (`seen=NNNs ago`). Filters replace
the grep pipeline every fleet script started with:

```
kazi bus who --project <dir>      # sessions whose cwd is <dir> or under it
kazi bus who --machine <host>     # sessions on that machine (exact hostname)
```

New sessions appear on their first bus call — orchestrators should have
members run `kazi bus join <team>` at session start so the roster is
explicit rather than implicit.

Every `bus` verb prints a one-line `no daemon running -- start one with
\`kazi daemon start\`` error (exit 1) when the daemon socket is down, instead
of raising.

`kazi bus read` normally ACKs (consumes) every message it pulls, so a second
`bus read` never re-delivers it. `--peek` (or the standalone `kazi bus peek`)
is NON-DESTRUCTIVE: it NAKs instead of acking, so the pending messages are
shown but stay pending — a subsequent `bus peek` sees the same messages again,
and a subsequent `bus read` still consumes them normally (issue #1059).

### The digest is the default on every machine path (ADR-0072)

Under `--json`, `bus read`/`bus peek`/`bus watch` return the DIGEST by
default — the same summary the TTY prints, as a versioned envelope
(`schema_version`, introspectable via `kazi schema bus`; contract:
`docs/schemas/bus-digest.md`):

- **Verbatim** lines only for directed messages (`kind: msg`) and
  `sev: interrupt` — each carries `id`, kind, topic, sev, provenance
  (session/machine/ts), byte size, and the full `text`.
- **Stub** lines for ANY body over the 1024-byte render threshold —
  including directed/interrupt: the same fields WITHOUT `text`. The body
  stays in the stream (the 64 KiB cap and 30-day retention are unchanged),
  addressable by its `id`.
- **Count** lines for everything else: one exact-count line per
  `{kind, topic}` pair with the group's `first_id`/`last_id`,
  most-frequent first. A `fact` count line also carries `last` — the
  CURRENT value for that topic, since a fact states what is true now
  rather than that three things were said.
- The whole digest is bounded to **40 lines** regardless of backlog size;
  a tail past the bound folds into one exact-count `overflow` line.
  `digest.total` is always the exact number of messages pulled.

`--full` is the documented escape for debugging: it replaces `digest` with
`messages` — every pending message unabridged, each carrying its `id`.
Sessions that previously parsed `.messages[]` from `bus read --json`
should either consume the digest (the point: a thousand-message backlog
costs the same context as forty lines) or pass `--full` for the old shape.

#### The DAEMON assembles it (T55.7, ADR-0072 d5)

`bus read`/`bus peek` send `read` over the daemon's control socket. The
daemon pulls the consumer, aggregates, and enforces the bound BEFORE the
bytes reach a client; the client only renders. This is ADR-0067 point 5's
own argument — *"only a server can aggregate before the tokens are spent"* —
and it is why the CLI, the `kazi_bus_*` MCP tools, and the installed hook
return identical digests: the bound is written once, not three times.

Two consequences worth knowing:

- **A deep backlog costs one read.** `Kazi.Bus` pulls in batches of 100, so
  a client-side read of a 200-message backlog saw half of it. The daemon
  walks the whole pending set and aggregates it into ONE digest.
- **`--full` is the one mode the daemon does NOT assemble.** There is no
  digest to assemble, and its size is bounded by nothing, so it reads the
  consumer directly. The control socket must never carry an unbounded
  payload: `packet: :line` truncates an over-long line silently
  (`docs/lore.md`), so the daemon refuses `full` outright rather than
  quietly answering with a digest instead.

With the daemon down, every one of these surfaces still reports the clean
one-line no-daemon error and exits 1 — moving assembly server-side did not
make the bus a dependency of anything (ADR-0067 point 1).

### The board: current state, not a delta (T55.4, ADR-0073)

`read`/`peek`/`watch` answer *"what changed since I last looked"* — a delta of
pending stream messages, and no state. `kazi bus board` answers *"what is true
right now"*: the last-value `fact` per topic plus the live roster (names, teams,
liveness), projected in one shot. It is the surface a session reads to orient at
session start, and the replacement for the hand-rolled markdown blackboards
teams used to keep (which could not see a second machine — the board can).

```
kazi bus board [--scope machine|project] [--json]
```

The board is **cursor-free and idempotent**: unlike `read`, it CONSUMES NOTHING
and keeps no cursor, so a session may read it every turn without draining a
message a later `read`/`watch` was counting on (the `read` ack landmine). The
facts come off a throwaway ephemeral consumer with JetStream's
`last_per_subject` delivery — entirely separate from the durable read cursors —
so posting three facts on one topic renders ONE current line (the latest value,
not three).

It is bounded by the SAME digest rules as `read` (ADR-0072): an oversize fact
body renders as a one-line stub carrying its `id` (the body stays addressable in
the stream), and the fact section is at most 40 lines regardless of topic count,
the tail folding into one `overflow` line. Under `--json` (contract:
`kazi schema bus`):

```json
{
  "ok": true,
  "schema_version": 2,
  "board": {
    "facts": [{"type": "verbatim", "topic": "ci", "text": "main is green", "id": 42, "...": "..."}],
    "roster": [{"session": "s-abc", "name": "reviewer", "team": "wave1", "machine": "host", "liveness": "active"}],
    "claims": [{"task": "T55.8", "owner": "dev@example.com", "host": "build-box", "age_s": 90}],
    "claims_available": true,
    "total_facts": 1,
    "total_sessions": 1,
    "total_claims": 1
  }
}
```

The roster is the same presence path `bus who` reads, projected to stable
identity fields only (session, name, team, machine, liveness) and ordered by
session id — deliberately NOT the age/heartbeat fields, so back-to-back boards
over the same live set render identically.

#### Claim ownership: read at source (T55.8, ADR-0073 point 2)

The `claims` section is a **direct projection of `refs/claims/*` on the shared
remote** — the same atomic git-ref locks `/claim` takes. Claims are *already*
cross-machine (the claim primitive pushes every claim to `origin`) and *already*
self-describing (the claim commit's subject is `claim <task> by
<identity>@<host> <stamp>`), so the board reads them straight at source: one
short-timeout `git fetch` of the claim refs, projected to `{task, owner, host,
age_s}` per claim. There is **no copy to drift, no staleness class, and no
daemon anywhere in the claim path** — claiming and *seeing* claims both work
with the daemon down, by construction.

When the remote is unreachable inside the timeout the section degrades to a
single honest line rather than a possibly-stale table:

```
claims: unavailable (remote unreachable)
```

and `--json` carries `"claims_available": false` with an empty `"claims"`. A
stale local ref cache is **never** presented as live truth.

The board only ever *shows* claims — it never grants, arbitrates, or expires
them (ADR-0067 non-goal, reaffirmed). One caveat on `owner`: a claim commit is
minted as the repo's configured git identity, so N pool sessions on one machine
all claim as the SAME `owner` string (docs/lore.md L-0037) — the field is honest
about what it is (git identity + host) but cannot yet tell sibling pool sessions
apart.

**Optional digest one-liner (a convention, not a mechanism).** A claim *wrapper*
script MAY, on its own, best-effort post a fact when it takes a claim, so that a
turn-boundary **digest** can announce the event:

```
kazi bus post fact "claimed T55.8" --topic claims
```

This is purely optional and lives in the operator's own claim tooling (outside
kazi's delivery, ADR-0067 point 6). The board **never** renders ownership from
such posts — its `claims` section reads `refs/claims/*` at source and nothing
else — so claim visibility is fully correct whether or not the convention is in
use. kazi ships no claim wrapper; it only documents the convention.

### Run-lifecycle mirroring (T51.5, ADR-0067 point 1)

A `kazi apply` run MIRRORS its lifecycle onto the bus as best-effort `fact`s,
so a session watching the bus sees a long run's live state instead of only a
growing JSONL sink it cannot watch. Three posts, all on ONE topic per run —
`run:<short-run-id>` — so the board's last-value-per-topic retention collapses
them to ONE current line per run:

- **started** when the run begins — `started <goal-ref>`;
- **iter N: p/t passing** once per iteration — the iteration index and the
  predicate pass/total, with a `(k regressed)` suffix when predicates went
  green→red that observation;
- **`<verdict>` \<goal-ref\> (p/t passing, N iters)** at termination — the
  honest verdict (`converged` / `stuck` / `over_budget` / `stopped` / `error`).

The sender identity rides the fact header (the run's `--session-name`), so a
supervisor sees WHICH session's run it is. Because the posts share one topic,
`kazi bus board` shows the run's *current* state (`iter 7: 5/8 passing`), while a
`bus read`/`watch` stream sees each event as it happens.

**The bus is a MIRROR, never a dependency** (ADR-0067 point 1, pinned by test):
a goal converges byte-identically with the daemon down. Every post is
fire-and-forget and every error / timeout / daemon-down is swallowed — the
reconcile loop's outcome can never turn on whether a daemon is up. The
per-iteration post is made detached so it adds no latency to the loop; the start
and terminal posts wait a bounded moment so the verdict lands before a one-shot
`kazi apply` process exits. There is no flag: mirroring is automatic and costs
nothing when no daemon is running.

### Fetching a stubbed body: `bus get <id>` (T55.6, ADR-0072 d3)

The digest keeps routine reads cheap by collapsing a large body into a
one-line **stub** — but that stub carries the body's `id`, so the body is
never a dead end. `kazi bus get <id>` is the deliberate pull that
dereferences that id back to the full body: the escape a session takes ON
PURPOSE once it has decided a stubbed document is worth spending the context
on.

```
$ kazi bus read                          # a 60 KiB design doc shows as a stub
1 note/design                            #   (id 812, 61440B, no body)
$ kazi bus get 812 --full                # deliberately fetch the whole body
812 note/design 61440B session=architect machine=host-3
<the full 60 KiB body, byte-identical to what was posted>
```

It is implemented as a **direct JetStream stream GET by sequence** — NO
consumer is involved, so `get` **consumes nothing** and never advances any
read cursor. This is the sharp contrast with `bus read`, which acks and
consumes: a `get` can be spent freely and a later `bus read` still delivers
that same message normally. (Nor does it disturb another session's inbox —
`get` is a pure read of the shared stream.)

By default `get` prints an `id kind/topic bytes` header and a **bounded
preview** of the body (the same 1024-byte threshold that stubbed it); `--full`
prints the whole body. Under `--json` the result is a versioned envelope
`{ok, schema_version, message: {id, scope, kind, topic, sev, session,
machine, ts, bytes, text, truncated}}` — `truncated` is `true` when the
default preview cut the body, and `--full` returns the whole `text` with
`truncated: false`. An id that is not in the stream (never posted, or aged
out of the 30-day retention) is a clean one-line error, never a crash.

## Cross-machine setup

ADR-0067 designed the bus for cross-machine from day one ("One machine today,
a cluster later, with no protocol change") and describes `kazi daemon` as
supervising a local `nats-server` "or connects to an external one via
config" — this is that config change, no redesign required.

Pick one machine to HOST the shared bus and run it normally:

```
kazi daemon start [--nats-token <token>]
```

That machine spawns and supervises the nats-server, same as single-machine
use today. `nats-server` binds all interfaces by default (kazi passes no
bind-address restriction), so it's already reachable from the LAN.

Every OTHER machine CONNECTS instead of spawning:

```
kazi daemon start --nats-host <hosting-machine-host-or-ip> --nats-port <its-port> [--nats-token <same-token>]
```

`--nats-host` needs no local `nats-server` binary — it skips spawn entirely
and points this machine's daemon at the shared one. Once connected, `kazi bus
who` / `read` / `post` / `tell` on EVERY connected machine see the same
presence, facts, and events — no other config.

**Security.** The supervised `nats-server` runs with no auth by default —
fine bound to loopback (single-machine, today's default), **not fine**
exposed on a LAN. Set a shared token with `--nats-token <token>` (or the
`KAZI_NATS_TOKEN` env var) on the hosting machine, and pass the SAME token to
every connecting machine's `--nats-host` invocation. Running cross-machine
without a token means the bus is unauthenticated on the LAN — anyone who can
reach the port can read and post.

## MCP tools

The same verbs are exposed through `kazi mcp` (ADR-0044) so an MCP-speaking
harness drives the bus natively, with no JSON-CLI shell-out:

| Tool | Mirrors | Required args |
|---|---|---|
| `kazi_bus_post` | `kazi bus post` | `kind`, `text` |
| `kazi_bus_read` | `kazi bus read` (`peek: true` mirrors `kazi bus peek`) | — |
| `kazi_bus_watch` | `kazi bus watch` | — |
| `kazi_bus_who` | `kazi bus who` | — |
| `kazi_bus_board` | `kazi bus board` | — |
| `kazi_bus_tell` | `kazi bus tell` | `session`, `text` |
| `kazi_bus_status` | `kazi bus status` | `id` |
| `kazi_bus_get` | `kazi bus get` | `id` |
| `kazi_bus_name` | `kazi bus name` | `name` |

Each accepts the optional `topic` / `scope` / `sev` arguments the CLI verbs
take. `kazi_bus_tell`'s `session` accepts a session id, a nickname, or
`@<team>`, exactly like the CLI verb (T55.5), and it returns the T55.12
receipt — `{ok: true, id, recipient, liveness}` — where `id` is what
`kazi_bus_status` dereferences and a `liveness` of `"dead-reaping"` /
`"no-presence"` is the structured form of the CLI's warning. `kazi_bus_status`
returns `{ok: true, id, state, recipient, sent_at, recipients}` with `state`
`"pending"` or `"consumed"`; `unknown_message` and `not_directed` are its
structured errors. `kazi_bus_get` dereferences a stub's `id` back to the full
body (T55.6) and returns `{ok: true, message: {id, scope, kind, topic, sev,
session, machine, ts, bytes, text, truncated}}` — a bounded preview by default
(`truncated: true` when cut), the whole body under `full: true` — consuming
nothing, so a later `kazi_bus_read` still delivers that message; `unknown_message`
is its structured error. `kazi_bus_who`'s rows carry `inbox` (un-read directed
depth). `kazi_bus_read` and
`kazi_bus_watch` return the ADR-0072 digest envelope by default (see
above); `full: true` mirrors the CLI's `--full` and returns `messages`
unabridged. `kazi_bus_watch` takes an optional `timeout` (seconds) and
`since` (`"now"` default / `"all"` / a numeric stream sequence — the
CLI's `--since` anchor, issue #1097); where the CLI exits 3 on expiry,
the tool returns `{ok: true, timed_out: true, digest: {total: 0, lines:
[]}}` (`messages: []` under `full: true`) — an expected outcome the agent
branches on, never
`isError`. A tool call against a missing daemon returns an MCP tool-result error
(`isError: true`) with `reason: "no_daemon"`, exactly mirroring the CLI's
no-daemon message — never a JSON-RPC protocol error.

## Installing delivery (ADR-0076)

Delivery into a session ships as an **installer, not a recipe**: the
DIY-hook recipe this section used to carry had an observed install rate of
zero, so [ADR-0076](adr/0076-bus-delivery-is-installed-not-documented.md)
supersedes it. One opt-in command registers everything:

```
kazi install-hooks                # user-level ~/.claude/settings.json (default)
kazi install-hooks --local        # this repo's LOCAL .claude/settings.local.json
kazi install-hooks --uninstall    # remove exactly what was added
```

It registers two hooks in the Claude Code settings, matched to the two
moments that matter — and bound ONLY to events whose stdout reaches the
session's context (the ADR-0076 binding rule; a `Stop` hook's output never
reaches the next turn, so binding there is delivery to nowhere):

| Claude Code event | Runs | Delivers |
|---|---|---|
| `SessionStart` | `kazi bus hook session-start` | registers presence, joins the project-scope team, and injects the current board (`bus board`) to orient the new session |
| `UserPromptSubmit` | `kazi bus hook turn` | injects the bounded digest (`bus read`) when there is traffic since the session's last turn, and is COMPLETELY SILENT (zero bytes) when the bus is quiet |

The registered command is a kazi subcommand, not a script file, so the
payload logic upgrades with the binary. What each event injects (T55.9):

- **`session-start`** registers presence, joins the team named for the
  project (the git toplevel slug), and injects the current board — the
  last-value fact per topic plus the live roster, bounded by the ADR-0072
  digest rules.
- **`turn`** injects the digest of what arrived since the session last
  looked. It uses `read` (which ACKS what it shows), so the durable cursor
  IS the "last checked" marker: a turn with new traffic renders the bounded
  digest, and the next quiet turn drains nothing and prints **zero bytes**.
  That silent-when-quiet property is what makes ambient awareness free — it
  is why the hook ends the token-cost complaint.

Its contract: **always exit 0, never block.** With no daemon running (or an
unknown event) `kazi bus hook` prints nothing and returns immediately. And a
hard wall-clock bound applies even to a HUNG daemon (one that accepted the
connection but never answers): the payload is computed in a bounded task and
only written if it returns within budget, so a slow or stalled daemon can
never tax or break a turn (the graceful-degradation guarantee above extends
to delivery).

That bound is **per-event**, and the asymmetry is deliberate (issue #1295):

- **`turn` stays tight at 2s.** It runs on every prompt of every session on
  the machine — the per-turn hot path — so a hung/slow daemon must never add
  more than ~2s there. A hung daemon adding seconds to every turn is worse
  than any missed digest.
- **`session-start` gets a larger 15s bound.** It is a ONE-SHOT at session
  boot, and its board renders the FULL current-state projection, whose
  client-side fact drain scales with the fact-topic space: under a real busy
  backlog (127+ fact topics) `bus board` was measured at ~9.7s — the exact
  team-that-nobody-reminds load the board exists for. Under the old shared 2s
  bound the board was silently `Task.shutdown`'d to nothing, so a starting
  session got NO board precisely when it needed one (issue #1295). 15s matches
  the bus's own control-socket call bound, so the hook no longer kills a call
  the daemon would have answered. A human is already waiting for their session
  to start, so a few extra seconds ONCE is invisible — the same cost on every
  turn would not be. **Do not collapse these back to one shared constant.**

The installer merges, never clobbers: an operator's own hooks and keys
survive byte-identically, re-running is a no-op, and `--uninstall` right
after a fresh install restores the pre-install bytes exactly. A malformed
settings file fails with one clear line and writes nothing. The default
target is user-level because the hook no-ops instantly wherever no daemon
runs — one install covers every project; `--local` writes the repo's
*local* (uncommitted) settings file, and the installer never writes a
committed project file (ADR-0034).

Injected bus content remains advisory, provenance-stamped input (the
contract above) — injection is exactly the moment that matters, since a
hook folds agent-authored text into another agent's context.

For background waiters (not turn-boundary delivery), prefer `kazi bus watch`
over a `read`-in-a-loop: it blocks server-side until traffic arrives
instead of spawning the CLI on an interval (issue #1091). That is the other
half of delivery — see the wake contract below.

## The wake contract — how an idle worker sleeps and gets woken

Installed delivery lands at TURN BOUNDARIES. An idle session has no next turn,
so it has no boundary to deliver into: a `tell` to a session that is sitting
idle is stored and queued, and nobody is woken. The send even looks like it
worked —

```
$ kazi bus tell worker-a "you own T12 now"
told worker-a (id 4127)
$ kazi bus status 4127
4127 pending recipient=worker-a sent=...
```

— and `pending` is where it stays. Nothing is lost (the message keeps, and
`bus who` counts it in that session's `inbox` depth), but nothing happens
either. This is the failure the wake contract prevents, and it is the reason a
fleet's idle workers look like they are ignoring their supervisor.

The contract has two halves. Which one applies depends only on whether the
target session is ACTIVE or IDLE.

### An ACTIVE session: `tell --sev interrupt`

A session that is working has a turn boundary coming, so delivery already
works. Address it and mark the message interrupt:

```
kazi bus tell <session> "rebase onto main first" --sev interrupt
```

The digest renders directed (`kind: msg`) and `sev: interrupt` messages
VERBATIM instead of folding them into a count line (ADR-0072), so it arrives as
text the session reads rather than a number it skims past. This half is
field-confirmed on a live fleet: it works, and it is the right tool whenever
the recipient is doing something.

Its limit is exactly the idle case — no turn, no boundary, no delivery.

### An IDLE worker: park a `bus watch` as a background task

A worker with nothing to do should not poll `bus read` on a timer, billing a
turn's tokens per tick to usually discover silence. It should SLEEP. The way to
sleep on the bus is to park a bounded watch as a **background task of the
worker's own harness**:

```
kazi bus watch --timeout 600 --json
```

The pattern needs exactly two things from the harness, and nothing from kazi
beyond the verb above: it must be able to run a shell command as a background
task, and the completion of that task must re-invoke the session. A harness
with both (Claude Code is one) gets the whole contract for free:

- **Exit 0 — arrival is the wake, with the message already in hand.** The
  completed task's own output IS the digest, so the session wakes up already
  holding what woke it. No follow-up `read`, no second call to discover why it
  was woken, no cursor left behind: the watch consumed the message.
- **Exit 3 — the timeout expired and nothing happened. Re-park.** A timeout is
  a non-event, always distinguishable from an arrival, so re-parking is the
  whole handler.

**Arrival wakes; timeout re-parks.** That is the contract. The worker is asleep
in between — costing no tokens, blocked server-side rather than spinning — and
a parked watch also refreshes the worker's presence, so an idle-but-parked
worker stays `active` on `bus who` and never ages out of the roster. A
supervisor's `tell` to it reports `liveness: active`, and `bus status <id>`
turns `consumed` the moment the wake happens: the whole round trip is visible
from the sending side.

A harness that cannot re-invoke a session on a background task's completion has
no wake mechanism, and its sessions keep using the pull verbs at turn
boundaries — exactly as ADR-0076 says of a harness with no hook mechanism.

### This depends on `--since now` (T54.9, issue #1097)

The default `--since now` anchor is what makes a parked watch a SLEEP rather
than a poll, and the pattern above is unusable without it.

`--since now` anchors on the stream's current last sequence, so only messages
posted AFTER the park starts satisfy the watch; backlog already pending on the
session's cursor stays pending for `bus read`/`bus peek`. Every wake is
therefore a real event. Under the pre-T54.9 drain-first behavior (still
available, deliberately, as `--since all`) a parked watch returns IMMEDIATELY
on any pending backlog — including messages an earlier `bus peek` already
looked at. A worker that re-parks on completion would then wake on stale
backlog, re-park, and wake again at full tick rate: the pattern degenerates
into precisely the poll loop it exists to replace.

So: take the default for a wake. Use `--since all` only for a deliberate
drain-first watch, never for a park.

`--since` on `bus read` is a DIFFERENT flag with different accepted values
(T55.7). The two are deliberately not interchangeable, and the shared name is
the trap:

| | `bus watch --since` | `bus read --since` |
|---|---|---|
| accepts | `now` (default), `all`, or a sequence | a sequence ONLY |
| asks | "tell me WHEN something new arrives" | "what have I MISSED since this point?" |
| blocks | yes — it is a park | no — it returns immediately |

`bus read --since all` is therefore an error, not a drain: a read is not a
park, so "wake me on new" has no meaning for it, and a plain `bus read`
already drains everything pending.

### Out of boundary: kazi does not type into your session

kazi will never wake a session by reaching into it. There is no supported way
to make kazi inject a prompt, drive a terminal, or resume a live harness
process, and there will not be one.

This is worth stating plainly because the alternative has been tried under
field pressure: a fleet with no documented wake contract resorted to scripting
its terminal emulator to inject keystrokes into an idle session's TTY. It cost
a day to discover that the scripting verb types text without submitting it (an
explicit carriage return had to be sent separately), and the result was fragile
and platform-specific, breaking whenever TTYs were renumbered.

That pain is the argument for documenting this contract — not for building an
escape hatch. Reaching into a live harness is permanently outside kazi's
boundary: ADR-0001 positions kazi as the outer loop that treats the harness as
a replaceable inner loop invoked through a thin subprocess adapter, and
ADR-0076's non-goals restate it for exactly this surface ("kazi does not reach
into a live harness process, does not inject mid-turn, and does not require the
harness to be running"). A wake that requires kazi to drive someone else's
terminal would make kazi a harness. The supported wake is the harness's own
background-task mechanic — which the harness already owns, and which kazi
therefore never has to reach into.

### When to use harness-native agent teams instead

If the sessions you want to coordinate are ones your own session SPAWNED — one
lead, one machine, one session lifetime — the harness's native agent teams are
the better mechanism and the bus is the wrong tool. Claude Code's teams cover
that shape natively: automatic message delivery to teammates, a roster, and a
dependency-aware task list, with no daemon to run and no wake contract to
arrange. Inside a team, the native mechanism already wakes the workers; adding
the bus buys nothing and costs a moving part.

The bus is for the sessions **nobody spawned**: independently-started peers,
across machines, surviving a restart, harness-agnostic, and tied to kazi's own
objective state (claims, runs, the board). Agent teams are structurally
single-session and single-machine today — one team per session, mailboxes on
the local filesystem, the team directory removed at session end — so none of
those properties are available inside one.

> **Teams orchestrate the workers one session spawns; the bus coordinates the
> sessions nobody spawned.**

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
  pid, liveness, cwd, last-seen). Rows record the caller's pid AND its
  process start time, so liveness checks are pid-reuse-proof (T55.11).
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
kazi bus read [--peek] [--full] [--json]                   # pull + ack this session's durable consumers, prints a digest
kazi bus peek [--full] [--json]                            # non-destructive read (issue #1059): same as `bus read --peek`
kazi bus watch [--timeout <seconds>] [--since <seq|now|all>] [--full] [--json]  # BLOCK until a NEW message arrives (#1091/#1097); exit 3 on timeout
kazi bus who [--team <t>] [--project <dir>] [--machine <host>] [--all] [--json]
                                                           # roster with liveness (active|idle) + inbox depth; --all includes stale rows
kazi bus join <team>                                       # named-team membership (issue #1069)
kazi bus leave                                             # clear team membership
kazi bus name <nickname>                                   # assign a durable, addressable session name (T55.5, ADR-0073)
kazi bus hook <event>                                      # harness hook entry point (ADR-0071) -- ALWAYS exits 0 silently
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
  reuse cannot resurrect a dead session). The sweep deletes such rows on
  its next pass — this also retires legacy `os-<pid>` ghost rows.

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
  most-frequent first.
- The whole digest is bounded to **40 lines** regardless of backlog size;
  a tail past the bound folds into one exact-count `overflow` line.
  `digest.total` is always the exact number of messages pulled.

`--full` is the documented escape for debugging: it replaces `digest` with
`messages` — every pending message unabridged, each carrying its `id`.
Sessions that previously parsed `.messages[]` from `bus read --json`
should either consume the digest (the point: a thousand-message backlog
costs the same context as forty lines) or pass `--full` for the old shape.

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
| `kazi_bus_tell` | `kazi bus tell` | `session`, `text` |
| `kazi_bus_status` | `kazi bus status` | `id` |
| `kazi_bus_name` | `kazi bus name` | `name` |

Each accepts the optional `topic` / `scope` / `sev` arguments the CLI verbs
take. `kazi_bus_tell`'s `session` accepts a session id, a nickname, or
`@<team>`, exactly like the CLI verb (T55.5), and it returns the T55.12
receipt — `{ok: true, id, recipient, liveness}` — where `id` is what
`kazi_bus_status` dereferences and a `liveness` of `"dead-reaping"` /
`"no-presence"` is the structured form of the CLI's warning. `kazi_bus_status`
returns `{ok: true, id, state, recipient, sent_at, recipients}` with `state`
`"pending"` or `"consumed"`; `unknown_message` and `not_directed` are its
structured errors. `kazi_bus_who`'s rows carry `inbox` (un-read directed
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

## Installing delivery (ADR-0071)

Delivery into a session ships as an **installer, not a recipe**: the
DIY-hook recipe this section used to carry had an observed install rate of
zero, so [ADR-0071](adr/0071-bus-delivery-is-installed-not-documented.md)
supersedes it. One opt-in command registers everything:

```
kazi install-hooks                # user-level ~/.claude/settings.json (default)
kazi install-hooks --local        # this repo's LOCAL .claude/settings.local.json
kazi install-hooks --uninstall    # remove exactly what was added
```

It registers two hooks in the Claude Code settings, matched to the two
moments that matter — and bound ONLY to events whose stdout reaches the
session's context (the ADR-0071 binding rule; a `Stop` hook's output never
reaches the next turn, so binding there is delivery to nowhere):

| Claude Code event | Runs | Delivers |
|---|---|---|
| `SessionStart` | `kazi bus hook session-start` | presence + the project board at session start |
| `UserPromptSubmit` | `kazi bus hook turn` | the traffic digest at each turn boundary — silent when the bus is quiet |

The registered command is a kazi subcommand, not a script file, so the
payload logic upgrades with the binary. Its contract: **always exit 0,
never block** — with no daemon running (or an unknown event) `kazi bus
hook` prints nothing and returns immediately, so a hook can never break or
tax a session (the graceful-degradation guarantee above extends to
delivery). The delivered payload lands in a later release; the
registration surface and contract are stable now.

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
instead of spawning the CLI on an interval (issue #1091).

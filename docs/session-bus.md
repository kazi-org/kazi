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
  short-TTL KV bucket — `kazi bus who` lists who's currently active
  (session, pid, cwd, last-seen).
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
kazi bus tell <session>|@<team> <text> [--sev info|interrupt] [--scope machine|project]
kazi bus read [--peek] [--full] [--json]                   # pull + ack this session's durable consumers, prints a digest
kazi bus peek [--full] [--json]                            # non-destructive read (issue #1059): same as `bus read --peek`
kazi bus watch [--timeout <seconds>] [--since <seq|now|all>] [--full] [--json]  # BLOCK until a NEW message arrives (#1091/#1097); exit 3 on timeout
kazi bus who [--team <t>] [--all] [--json]                 # list fresh presence; --all includes TTL-stale entries
kazi bus join <team>                                       # named-team membership (issue #1069)
kazi bus leave                                             # clear team membership
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

### Teams (issue #1069)

`kazi bus join <team>` registers the session under a named team; presence
carries the membership across every later bus call, `bus who --team
<team>` lists the roster, and `bus tell @<team> <text>` reaches every
member. Membership ages out with presence (the 10-minute TTL) when a
session goes idle and vanishes on `bus leave` — a live roster rather than
a static list. Sessions that keep a `bus watch` open stay fresh
indefinitely.

### Presence freshness

`bus who` hides entries older than the presence TTL (10 minutes), so
closed sessions age out instead of looking active; `--all` shows
everything, age-annotated (`seen=NNNs ago`). New sessions appear on their
first bus call — orchestrators should have members run `kazi bus join
<team>` at session start so the roster is explicit rather than implicit.

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

Each accepts the optional `topic` / `scope` / `sev` arguments the CLI verbs
take. `kazi_bus_read` and `kazi_bus_watch` return the ADR-0072 digest
envelope by default (see above); `full: true` mirrors the CLI's `--full`
and returns `messages` unabridged. `kazi_bus_watch` takes an optional
`timeout` (seconds) and `since` (`"now"` default / `"all"` / a numeric
stream sequence — the CLI's `--since` anchor, issue #1097); where the CLI
exits 3 on expiry, the tool returns `{ok: true, timed_out: true, digest:
{total: 0, lines: []}}` (`messages: []` under `full: true`) — an expected
outcome the agent branches on, never
`isError`. A tool call against a missing daemon returns an MCP tool-result error
(`isError: true`) with `reason: "no_daemon"`, exactly mirroring the CLI's
no-daemon message — never a JSON-RPC protocol error.

## Turn-boundary hook recipe

Delivery into a session is the harness's own hook mechanism, not something
kazi reaches into (ADR-0001/0008 keep kazi driving harnesses, not embedding in
them). Wire a turn-boundary hook that shells out to `kazi bus read --json` and
folds the digest into the next turn's context — for Claude Code, a
`UserPromptSubmit` or `Stop` hook is a natural fit:

```bash
#!/usr/bin/env bash
# .claude/hooks/bus-read.sh — surface the session bus digest each turn.
digest=$(kazi bus read --json 2>/dev/null)
printf '%s' "$digest" \
  | jq -r 'if .ok then (.digest.total | tostring) + " bus message(s) since last read" else empty end'
```

If no daemon is running the command exits non-zero silently (`2>/dev/null`
swallows the one-line error) — the hook is a no-op, matching the
graceful-degradation guarantee above.

For background waiters (not turn-boundary hooks), prefer `kazi bus watch`
over a `read`-in-a-loop: it blocks server-side until traffic arrives
instead of spawning the CLI on an interval (issue #1091).

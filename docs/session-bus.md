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
- **Kind.** A short label you choose (`note`, `fact`, `intent`, ...); `msg` is
  reserved for directed messages (`bus tell`).
- **Presence.** Every bus call upserts the caller's session into a
  short-TTL KV bucket — `kazi bus who` lists who's currently active
  (session, pid, cwd, last-seen).
- **Directed messages.** `kazi bus tell <session> <text>` publishes to
  `bus.<scope>.msg.<session>`; only that session's `bus read` durable consumer
  sees it (durable = a persistent read cursor: a second read never re-delivers
  an already-acked message).
- **The 1 KB cap.** `text` over 1024 bytes is rejected client-side, before any
  daemon connection is attempted — the cap forces one-line discipline at the
  producer so a `bus read` digest stays cheap to consume.

## The advisory contract (ADR-0067 point 7)

Every message carries its provenance (session, machine, timestamp). A reading
session should weigh bus content as background input, never as a command
channel that overrides the operator — an agent-authored message landing in
another agent's context is a mild prompt-injection surface, so treat bus
content the same way you'd treat any other untrusted external input.

## CLI

```
kazi daemon start [--nats-bin <path>] [--nats-port <n>]   # boot the daemon (foreground; operator backgrounds it)
kazi daemon status [--json]                               # ping the running daemon
kazi daemon stop                                          # clean shutdown

kazi bus post <kind> <text> [--topic <t>] [--sev info|interrupt] [--scope machine|project]
kazi bus tell <session> <text> [--sev info|interrupt] [--scope machine|project]
kazi bus read [--json]                                    # pull + ack this session's durable consumer, prints a digest
kazi bus who [--json]                                      # list current presence
```

Every `bus` verb prints a one-line `no daemon running -- start one with
\`kazi daemon start\`` error (exit 1) when the daemon socket is down, instead
of raising.

## MCP tools

The same verbs are exposed through `kazi mcp` (ADR-0044) so an MCP-speaking
harness drives the bus natively, with no JSON-CLI shell-out:

| Tool | Mirrors | Required args |
|---|---|---|
| `kazi_bus_post` | `kazi bus post` | `kind`, `text` |
| `kazi_bus_read` | `kazi bus read` | — |
| `kazi_bus_who` | `kazi bus who` | — |
| `kazi_bus_tell` | `kazi bus tell` | `session`, `text` |

Each accepts the optional `topic` / `scope` / `sev` arguments the CLI verbs
take. A tool call against a missing daemon returns an MCP tool-result error
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
  | jq -r 'if .ok then (.messages | length | tostring) + " bus message(s) since last read" else empty end'
```

If no daemon is running the command exits non-zero silently (`2>/dev/null`
swallows the one-line error) — the hook is a no-op, matching the
graceful-degradation guarantee above.

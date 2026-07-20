# The session-stats velocity collector (T67.3, ADR-0079)

The velocity dashboard (E67) fuses two agent populations: kazi-driven runs
(already instrumented in the read-model) and the operator's **interactive harness
sessions**, whose activity otherwise lives only in local transcript files outside
kazi. The session-stats collector is the plumbing that brings population 2 into the
read-model — as **aggregate counters only**, never transcript content.

## Opt-in (disabled by default)

The collector is **off on every machine until you explicitly opt in**. A machine
that has not opted in reads no transcript at all. Enable it either way:

- **Config:** in `config/config.exs` (or an environment override file):

  ```elixir
  config :kazi, :velocity_collector, enabled: true
  ```

- **Environment variable** (takes precedence when set):

  ```sh
  export KAZI_VELOCITY_COLLECTOR=1   # 1 | true | yes | on
  ```

`Kazi.Velocity.SessionCollector.enabled?/0` reports the effective state;
`SessionCollector.run/1` is a no-op returning `{:ok, :disabled}` when the collector
is off. Opt-in is **per machine** — the counters record which host produced them.

## What triggers it (T67.6)

The collector is driven in production by `Kazi.Daemon.VelocityTicker`, a supervised
GenServer in the **daemon's** supervision tree (the daemon owns the read-model write
path, ADR-0068). On a fixed interval it calls `SessionCollector.run/1`, so the
read-model rows the E67 velocity dashboard reads actually get written — without the
trigger the collector had no production caller and those tables stayed silently
empty. It rides the existing daemon lifecycle rather than adding a second transport
(ADR-0079). Both knobs live under the same config key:

```elixir
config :kazi, :velocity_collector,
  enabled: false,           # opt-in gate (above)
  interval_s: 300,          # seconds between collection passes (default 300)
  transcript_dir: "...",    # transcript root to scan; default ~/.claude/projects
  workspaces: []            # git workspaces to project delivery events from (below)
```

When the collector is **disabled**, the ticker still starts but performs no
collection and reads no transcript — each interval costs only the `enabled?/0`
check. Daemon boot never blocks on a slow first scan: the first collection runs on
the first timer tick, not during startup. A collector crash is logged and swallowed,
and the ticker is a `one_for_one` child, so a failure never takes down the daemon.
Cursors persist under `<KAZI_STATE_DIR>/velocity/cursors` so collection stays
incremental across daemon restarts.

**Bounded scan (#1606).** A pass never reads a whole transcript: for each file it
`stat`s the size and, if the cursor is already at EOF, skips it without a read, so a
steady-state pass over a large `~/.claude` tree costs only a stat per file and
finishes in seconds. When a transcript has grown, only the new bytes past the cursor
are read (a positioned `pread`, not a full-file read), capped at a per-pass
`:max_bytes` budget (default 8 MiB) — so a first scan of a very large tree advances
the cursors in bounded chunks across successive passes instead of one unbounded read
that overruns the ticker's `collect_timeout` and is killed every tick (the live
#1606 hang). The cumulative counters are identical either way; only how much a single
pass ingests is bounded.

**In-daemon writes go direct (T67.6 invariant).** The collector's default
read-model sink is `Kazi.ReadModel.Writer`, a *client* seam: when a daemon is alive
it routes the write over the daemon control socket to the single writer (ADR-0068).
The ticker, though, runs *inside* the daemon, so that probe would find the daemon
alive (itself) and the ticker would block on a control-socket round-trip the daemon
must serve — while `kazi daemon status` also calls into the ticker — self-deadlocking
the daemon. (This wedged v1.262.0 live: with the collector enabled the daemon went
0% CPU exactly one interval after boot, every status ping timing out, until killed.)
The daemon *is* the single writer, so the ticker injects
`SessionCollector.direct_write/1` — a direct `Kazi.Repo` upsert, the same mechanism
`Kazi.Daemon.Write` uses to apply a client batch — as the collector's write sink, and
its writes never touch its own socket. The cross-machine bus `fact` still dials the
socket to find the NATS port, but is bounded by `Kazi.Bus.run/3`'s hard deadline
(degrading to `:bus_unavailable` rather than blocking), so it cannot wedge the daemon.

## The delivery projection (T67.6 finding 2)

The E67 velocity dashboard has two halves: the **session counters** above, and a
**delivery** half — delivered plan tasks and claim→merge lead time derived from a
workspace's git history by `Kazi.ReadModel.DeliveryProjection` (T67.2). Like the
collector, that projection shipped with **no production caller**, so the delivery
tables stayed silently empty and the dashboard's delivery half rendered over
nothing. The same daemon ticker now closes that gap: after each session-collection
pass it projects every git workspace listed under `:workspaces`.

```elixir
config :kazi, :velocity_collector,
  workspaces: ["/abs/path/to/repo", "/abs/path/to/another"]
```

- **On the released binary, use `KAZI_VELOCITY_WORKSPACES`.** The `:workspaces`
  keyword above is compile-time config, baked into the shipped Burrito artifact as
  its default `[]`. Setting it at runtime through `config/runtime.exs` does **not**
  reach the ticker on the release binary: the daemon supervision tree (the ticker's
  `init/1`) boots before the `runtime.exs` config provider applies, so a
  provider-set value is invisible at init (T67.6 gap 4). The release-binary way to
  configure workspaces is the `KAZI_VELOCITY_WORKSPACES` environment variable — a
  colon-separated list of absolute git-workspace paths, read **directly at ticker
  init** and taking precedence over app-env:

  ```bash
  KAZI_VELOCITY_WORKSPACES=/abs/path/to/repo:/abs/path/to/another kazi daemon start
  ```

  Unset, the ticker falls back to the compile-time `:workspaces` config. Blank
  segments are trimmed. This mirrors `KAZI_VELOCITY_COLLECTOR` (the opt-in gate),
  which `SessionCollector.enabled?/0` likewise reads at call time.
- **Not gated on `enabled`.** Delivery projection reads only committed git history
  (never a transcript), so it runs whenever `:workspaces` is non-empty regardless of
  the session-collector opt-in. An empty list (the default) does no projection work.
- **Incremental & idempotent.** Each pass scans `<last_seen_commit>..HEAD` and
  upserts on a composed `dedup_key`, so a re-scan of unchanged history writes nothing
  new (same history in ⇒ same rows out).
- **Crash-isolated per workspace.** A workspace that does not exist, is not a git
  repo, or whose history is unreadable is logged and skipped — it never aborts the
  other workspaces, session collection, or the ticker itself.
- **In-daemon writes go direct (same T67.6 invariant).** The projection's default
  sink is `Kazi.ReadModel.Writer` (the socket-routing client seam); running inside
  the daemon it would self-deadlock exactly as the collector did, so the ticker
  injects `DeliveryProjection.direct_write/2` — a straight `Kazi.Repo` upsert — and
  its writes never touch the daemon's own control socket.

**Observability.** `kazi daemon status` prints a `velocity collector:` line —
`disabled`, `enabled (no run yet)`, or `enabled (last run <ts>, <n> session(s))` —
and a sibling `delivery projection:` line — `no workspaces configured` or `last pass
<ts>, <n> workspace(s), <m> event(s)`. Both come from real runs only; nothing is
fabricated when no collection or projection has happened yet. The same fields appear
under `"velocity"` (with a nested `"last_projection"`) in `kazi daemon status --json`.

**Deadline-kill counter (#1606).** A pass that overruns the hard
`collect_timeout_ms` deadline is killed and logged at `:error`. Because that `:error`
log did not always reach the LaunchAgent log file on the release binary, a pass that
was killed every tick looked indistinguishable from "no run yet". The ticker now also
keeps a run-lifetime `passes_killed` counter (with `last_kill_at`), surfaced in
`kazi daemon status`: when non-zero the collector line gains a
`-- WARNING: <n> pass(es) killed at deadline` suffix (and the raw counts appear in
`--json`). So a silently-dying pass is impossible — it is visible from status alone,
with no dependence on log delivery. In steady state the bounded scan above keeps the
counter at 0.

**Tick-lifecycle counters (#1606, tick-never-fires).** A later live observation
found a subtler failure: `enabled: true` with `passes_killed: 0` **and**
`last_run_at: null` after several tick windows — the pass never ran, and neither the
kill counter nor the run fields said why (`enabled` is read from the env at call
time, so it does not even prove the ticker armed its timer). The ticker now exposes
the full tick lifecycle in `kazi daemon status --json`, so the next observation is
conclusive rather than ambiguous:

| field | meaning |
|---|---|
| `interval_ms` | the interval the ticker armed at boot (independent of the env-read `enabled`) |
| `ticks_fired` | periodic ticks that actually spawned a pass — **0 means the timer never fired** (an arming/boot fault) |
| `passes_completed` | passes that returned results (a healthy collector) |
| `passes_killed` / `last_kill_at` | passes killed at the `collect_timeout` deadline |
| `passes_crashed` | passes that went DOWN below their guards without completing and without a deadline kill — previously a **silent** reset, now counted and logged at `:warning` |

The human `velocity collector:` line surfaces the first applicable warning: timer
never fired > passes crashing > passes killed. The ticker also logs an arming line
at boot (`velocity ticker armed — first tick in <n>ms`) so the LaunchAgent log shows
it armed.

**`KAZI_VELOCITY_INTERVAL_S`** (seconds) is read directly at ticker init, mirroring
`KAZI_VELOCITY_WORKSPACES`/`KAZI_VELOCITY_COLLECTOR`: it wins over the app-env
`interval_s`, so it is immune to the release-binary boot ordering (the supervision
tree boots before `config/runtime.exs` applies) AND lets an operator arm a short
interval to confirm the tick fires on the release binary without waiting the full
default 300s.

```bash
KAZI_VELOCITY_INTERVAL_S=10 KAZI_VELOCITY_COLLECTOR=1 kazi daemon start
```

## The privacy contract — what is and is NOT collected

The collector's payload is a **closed whitelist** of aggregate counters, defined
once in `Kazi.Velocity.Counters` and pinned by a payload-shape test
(`test/kazi/velocity/session_counters_wire_shape_test.exs`). Anything outside the
whitelist is structurally unable to cross the wire or reach the read-model.

**Collected (per session UUID):**

| field | meaning |
|---|---|
| `input_tokens`, `cached_input_tokens`, `cache_write_tokens`, `output_tokens`, `reasoning_tokens` | cumulative token counts (ADR-0046 cached-vs-fresh split; `nil` when the transcript never reports one — never coerced to 0) |
| `message_count`, `tool_call_count` | cumulative event counts |
| `active_time_s` | cumulative active-time seconds (inter-event gaps under a cap; idle gaps excluded) |
| `first_observed_at`, `last_observed_at` | the session's activity window (rate denominators) |
| `session_uuid` | the E65 session identity (join key to the run registry) |
| `session_name` | the daemon-assigned display alias (never a join key) |
| `machine` | the opted-in host that produced the counters |

**NEVER collected or shipped:** prompt or response text, message content, tool
**names**, tool inputs, file paths, or any other free-text label. The parser reads
only the numeric and timestamp fields it needs — content is never copied into the
accumulator in the first place (R-E67-3).

## How it ships (ADR-0079)

- **Incremental:** a machine-local byte cursor per transcript
  (`Kazi.Velocity.Cursor`) means each pass parses only bytes past the cursor and
  merges them into the carried cumulative totals.
- **Idempotent:** the counters are cumulative and the read-model row is upserted on
  `(session_uuid, machine)`, so re-scanning a transcript that has not grown yields
  the identical row — duplicate ships collapse to one current row.
- **One write path:** the read-model write routes through the daemon single-writer
  seam (`Kazi.ReadModel.Writer`, ADR-0068); the cross-machine ship is a bus `fact`
  on topic `session:<short-uuid>` (the T60.1 `BusMirror` last-value-per-subject
  pattern), not a second transport.
- **Format-fragility is bounded (R-E67-1):** all transcript-format knowledge lives
  in `Kazi.Velocity.TranscriptParser`; an unrecognised or malformed line is
  skipped, never a crash and never a wrong number.

## Not collected here

No completion date, ETA, or "estimated finish" is ever computed or stored — the
schema has no such column (ADR-0046). Every velocity number downstream (T67.4/T67.5)
is a rate or a ratio, labeled with its window.

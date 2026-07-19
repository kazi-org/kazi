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
  transcript_dir: "..."     # transcript root to scan; default ~/.claude/projects
```

When the collector is **disabled**, the ticker still starts but performs no
collection and reads no transcript — each interval costs only the `enabled?/0`
check. Daemon boot never blocks on a slow first scan: the first collection runs on
the first timer tick, not during startup. A collector crash is logged and swallowed,
and the ticker is a `one_for_one` child, so a failure never takes down the daemon.
Cursors persist under `<KAZI_STATE_DIR>/velocity/cursors` so collection stays
incremental across daemon restarts.

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

**Observability.** `kazi daemon status` prints a `velocity collector:` line —
`disabled`, `enabled (no run yet)`, or `enabled (last run <ts>, <n> session(s))`.
The run timestamp and session count come from real runs only; nothing is fabricated
when no collection has happened yet. The same fields appear under `"velocity"` in
`kazi daemon status --json`.

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

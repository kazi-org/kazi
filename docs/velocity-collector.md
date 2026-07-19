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

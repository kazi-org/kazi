# `kazi bus read|peek|watch --json` result — the digest envelope

T55.1 (ADR-0072 decisions 1, 2, 6): the versioned JSON object every
machine-readable bus read returns. The same shape backs the
`kazi_bus_read` / `kazi_bus_watch` MCP tools, so the CLI and MCP surfaces
cannot drift. Introspect it at runtime with `kazi schema bus`.

The **digest is the default**: token cost is bounded at render, not at
post. Reading a thousand-message backlog costs the same context as reading
forty lines (ADR-0067 point 5, finally honoured on the machine path).
`--full` (CLI) / `full: true` (MCP) is the documented escape for debugging:
it replaces `digest` with `messages`, every pending message unabridged.

## Top-level fields

| Field | Type | Description |
|---|---|---|
| `schema_version` | integer | The shared `--json` contract version (currently 2). |
| `ok` | boolean | `true` on a successful read. |
| `digest` | object | Default shape (absent under `--full`): `{total, lines}`, see below. |
| `messages` | array\<object\> | `--full` / `full: true` only (replaces `digest`): every pending message unabridged — `{id, scope, kind, topic, text, session, machine, ts, sev}`. |
| `timed_out` | boolean | `kazi_bus_watch` (MCP) only: `true` when the watch expired with no traffic — an expected outcome to branch on, never an error. The CLI signals the same via exit code 3. |

## The `digest` object

- `total` — the exact number of messages the read pulled (never truncated).
- `lines` — at most **40** entries regardless of backlog depth or message
  size. Each line carries a `type`:

| `type` | Fields | When |
|---|---|---|
| `verbatim` | `id`, `kind`, `topic`, `sev`, `session`, `machine`, `ts`, `bytes`, `text` | A directed message (`kind: msg`) or `sev: interrupt` whose body fits the render threshold. |
| `stub` | same as `verbatim` **without** `text` | ANY message whose body exceeds the **1024-byte render threshold** — including directed/interrupt. The body stays in the stream (64 KiB post cap and 30-day retention unchanged), addressable by `id`. |
| `count` | `kind`, `topic`, `count`, `first_id`, `last_id` | Everything else, collapsed per `{kind, topic}` with exact counts, most-frequent first. |
| `overflow` | `count`, `first_id`, `last_id` | At most one, always last: when even the line set would exceed the 40-line bound, the tail folds into one line with the exact message count it represents. |

`id` is the message's JetStream stream sequence — the public identifier
carried on every returned message, digest line, and stub, so anything a
digest names stays dereferenceable.

## Example

```json
{
  "schema_version": 2,
  "ok": true,
  "digest": {
    "total": 202,
    "lines": [
      {"type": "verbatim", "id": 412, "kind": "msg", "topic": "session-a",
       "sev": "info", "session": "session-b", "machine": "host1",
       "ts": "2026-07-16T12:00:00Z", "bytes": 14, "text": "review is done"},
      {"type": "stub", "id": 413, "kind": "note", "topic": "design",
       "sev": "info", "session": "session-c", "machine": "host1",
       "ts": "2026-07-16T12:01:00Z", "bytes": 61440},
      {"type": "count", "kind": "fact", "topic": "ci", "count": 200,
       "first_id": 210, "last_id": 411}
    ]
  }
}
```

# The fleet dashboard: run registry, starmap, `kazi dashboard` (ADR-0057)

The operator often runs several concurrent `kazi apply` sessions on one
machine. Without a fleet-wide surface, that's a black box: a one-shot CLI run
has no visible surface, and a dead run is indistinguishable from a converged
one. `kazi dashboard` closes that gap with three pieces that reuse what
already exists rather than rebuild it — the shared per-user SQLite
read-model, and the KaziWeb LiveView assets.

See [ADR-0057](adr/0057-fleet-observability-dashboard.md) for the full
decision and [docs/plans/E46.md](plans/E46.md) for the epic. This doc is the
cross-cutting overview; it grows as the epic's later tasks (the wave-band
goal-DAG layout, the attention queue, the convergence heatmap, transcript
peek) land.

## The run registry

Every `kazi apply` process upserts a row in the shared read-model's `runs`
table on start (`run_id`, `pid`, `workspace`, `goal_ref`, `harness`/`model`,
`started_at`), and heartbeats it (`heartbeat_at`) as it iterates. On exit it
records a terminal `status` (`"converged"` / `"stuck"` / `"over_budget"` /
`"error"`).

Liveness is **heartbeat staleness**, not an explicit "dead" flag — there is no
IPC and no port discovery. A run with no terminal status whose heartbeat is
older than the staleness threshold (90 seconds by default) is classified
**stale**: it crashed or hung rather than converging on purpose. A row is
never deleted; a dead run's last state is exactly the fleet dashboard's
post-mortem record. See `Kazi.ReadModel.RunRegistry` (`start/1`,
`heartbeat/1`, `finish/2`, `stale?/2`, `list_stale/1`).

## The starmap (`/starmap`)

The dashboard's home view renders one node per registered run, resolved to a
display state:

| State        | Meaning                                                          |
| ------------ | ----------------------------------------------------------------- |
| `landed`     | terminal status `"converged"` (ADR-0055: converged and landed)    |
| `converging` | no terminal status, heartbeating normally                          |
| `stale`      | no terminal status, heartbeat older than the staleness threshold  |
| `stuck`      | a terminal non-converging status (`stuck` / `over_budget` / `error`) |

alongside fleet-wide counts per state and each node's run tags
(`goal_ref`, `harness`/`model`). It is a pure read projection
([ADR-0011](adr/0011-slice3-operator-surfaces.md) reaffirmed at fleet scope):
it never mutates a run, a goal, or a lease.

This is the walking-skeleton slice of the full starmap design (ADR-0057): the
topological wave-band goal-DAG layout, the ranked attention queue, the
convergence heatmap, and transcript peek are later `kazi dashboard` surface
tasks (E46 Wave B/C) built on the same registry.

## The transcript sink (T46.3)

When a run is persisted (`persist?: true`, the default), every dispatch's raw
harness output is teed to a per-run `transcript.jsonl` under
`<sinks_dir>/<run_id>/transcript.jsonl` (`:kazi, :sinks_dir` app config,
falling back to `<user-home>/.kazi/runs`), and the path is recorded on the
run's registry row (`transcript_sink_path`). See `Kazi.Sink.Transcript`.

The sink is a **passive tee**: it never changes what a dispatch returns, and a
write failure is caught and logged rather than raised. Each line is a JSON
event — a harness's own structured stream events pass through as-is, and
plain-text stdout/stderr lines are wrapped as `{"type": "text", "text": ...}`
— so the file is valid JSONL regardless of which harness produced it.

Every string value is **redacted** (`Kazi.Redaction.redact/1`) before it
touches disk, matching the prompt and context-store paths — a secret shape in
the harness stream never lands in the transcript file. The sink also caps its
own size (10 MiB by default, overridable per-run); once a run's transcript
would exceed the cap, further events are dropped and a single `{"type":
"truncated"}` marker is appended so a reader can tell an intentionally
truncated transcript apart from a torn one. This tee is the file "transcript
peek" (E46 Wave B/C) will read from.

## `kazi dashboard`

```
kazi dashboard [--port <n>] [--bind <ip>]
```

Boots the web endpoint standalone — **no goal loop in the process** — against
the shared read-model + run registry, localhost-bound by default
(`127.0.0.1`); pass `--bind` explicitly to listen on a non-loopback address.
`--port`/`--bind` apply to a **fresh** standalone boot; if this process
already supervises the endpoint (the normal dev-server / `mix kazi.apply` /
test entry points), the verb reports the endpoint's existing bind instead of
rebinding it.

## Retention and scope

Single-machine scope for now: the shared SQLite read-model requires zero new
infrastructure. Cross-node fleets and the NATS fan-in stay Slice 3
(ADR-0057 §5) — this dashboard becomes that slice's first real consumer when
it arrives.

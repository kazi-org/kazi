# The fleet dashboard: run registry, starmap, `kazi dashboard` (ADR-0057)

The operator often runs several concurrent `kazi apply` sessions on one
machine. Without a fleet-wide surface, that's a black box: a one-shot CLI run
has no visible surface, and a dead run is indistinguishable from a converged
one. `kazi dashboard` closes that gap with three pieces that reuse what
already exists rather than rebuild it — the shared per-user SQLite
read-model, and the KaziWeb LiveView assets.

See [ADR-0057](adr/0057-fleet-observability-dashboard.md) for the full
decision and [docs/plans/E46.md](plans/E46.md) for the epic. This doc is the
cross-cutting overview; it grows as the epic's later tasks (the attention
queue, the convergence heatmap, transcript peek) land.

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

With no roadmap configured this flat list already satisfies "single-goal
groups" (ADR-0056): every run is its own node with no declared order between
them.

### Wave bands

When a roadmap ref IS configured (`KaziWeb.Starmap.GoalSource`, the ADR-0011
§3 injection seam — production defaults to `GoalSource.None`, i.e. no
roadmap), the starmap ADDITIONALLY lays that goal's `needs`-DAG out as
topological wave bands, reusing `Kazi.Goal.DepGraph.frontiers/1` — the exact
same computation `kazi apply --explain` prints, so the bands can never
disagree with the schedule a real `kazi apply --parallel` run would take.
Each band node's state extends the four run-registry states above with:

| State      | Meaning                                                                  |
| ---------- | ------------------------------------------------------------------------- |
| `claimed`  | every `needs` dep converged (the live frontier), but no run has started yet |
| `pending`  | still waiting on an unconverged dep (a later wave), or poisoned by a stuck ancestor |

Wiring a real roadmap ref into `kazi plan --project` / `kazi dashboard` is
future work (ADR-0056 §Decision 1 is not yet a first-class read-model
object); today `GoalSource` is a seam a caller (or a test) can point at any
`Kazi.Goal.t()`.

The ranked attention queue, the convergence heatmap, and transcript peek are
later `kazi dashboard` surface tasks (E46 Wave B/C) built on the same
registry.

## The events sink (T46.2)

When a run is persisted (`persist?: true`, the default), every observed
iteration is appended as one JSON line to a per-run `events.jsonl` under
`<sinks_dir>/<run_id>/events.jsonl` (the same `:kazi, :sinks_dir` app config
as the transcript sink, alongside `transcript.jsonl`), and the path is
recorded on the run's registry row (`events_sink_path`). See
`Kazi.Sink.Events`.

Each line is built from the SAME `Kazi.ReadModel.Iteration` row the read-model
projection just inserted for that observation — the predicate vector, the
`converged` flag, dispatch metadata (`action_kind`/`action_params`, e.g. a
budget-stop stamp), the regression-detector's green→red firings, the release
ref, and the ADR-0046 context/tool counters — so an events-sink line and its
read-model row can never disagree in shape or values. Every string value is
redacted the same way the transcript sink is. `Kazi.Sink.Events.read/1` tails
the file back into decoded maps and tolerates a torn final line (a process
killed mid-write) by dropping it rather than erroring the whole read.

Retention is a separate, explicit pass rather than something the write path
does automatically: `Kazi.Sink.Events.sweep/2` deletes a run's whole sink
directory once it is aged past `:max_age_seconds` (default 7 days,
`default_max_age_seconds/0`) OR sized past `:max_bytes` (default 200 MiB per
run directory, `default_max_bytes/0`) — except any run_id passed in
`:live_run_ids` (e.g. the non-stale rows from `Kazi.ReadModel.RunRegistry.list/0`),
which is never touched regardless of age or size.

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

A standalone boot serves **every** dashboard view (`/`, `/starmap`, `/goals`,
`/leases`, `/dag`, `/goals/:id/history`), with web-tree parity to the full
app's supervision tree: views whose live source has nothing to show (no
active run registered in this node) render their honest empty state, never a
500 (issue #801).

## Retention and scope

Single-machine scope for now: the shared SQLite read-model requires zero new
infrastructure. Cross-node fleets and the NATS fan-in stay Slice 3
(ADR-0057 §5) — this dashboard becomes that slice's first real consumer when
it arrives.

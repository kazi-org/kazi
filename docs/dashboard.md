# The fleet dashboard: run registry, starmap, `kazi dashboard` (ADR-0057)

The operator often runs several concurrent `kazi apply` sessions on one
machine. Without a fleet-wide surface, that's a black box: a one-shot CLI run
has no visible surface, and a dead run is indistinguishable from a converged
one. `kazi dashboard` closes that gap with three pieces that reuse what
already exists rather than rebuild it — the shared per-user SQLite
read-model, and the KaziWeb LiveView assets.

See [ADR-0057](adr/0057-fleet-observability-dashboard.md) for the full
decision and [docs/plans/E46.md](plans/E46.md) for the epic. This doc is the
cross-cutting overview; it grows as the epic's later tasks land.

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

## The starmap (`/`, alias `/starmap`)

The starmap is the landing page: the root route serves it directly, and
`/starmap` remains an alias for existing links. It renders one node per
registered run, resolved to a display state:

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

Converging, stuck, and claimed nodes carry session tags (`S1`, `S2`, ...)
mirrored into the rail's **SESSIONS** section (a stuck session's chip renders
red), so the rail always answers "who is driving what" — including a fleet
whose only live work is stuck. Clicking a SESSIONS row filters the
constellation to that session's goal (every other node and unrelated edge
dims); clicking the same row again — or the session ending — clears the
filter.

The FLEET tiles (RUNNING / LANDED / STUCK) filter the canvas the same way
the SESSIONS rows do: click a tile to dim everything but that state, click
it again to clear; the two filters are mutually exclusive. Dense fleets no
longer wrap nodes into sub-columns — each band is a single column and the
canvas grows downward and scrolls, which keeps `needs` edges on straight
sight-lines at any fleet size.

Each SESSIONS row identifies its run by the **operator-assigned session
name** when one was given (`kazi apply --session-name <label>`, or the
`KAZI_SESSION_NAME` environment variable — useful when an orchestrating
agent session labels every run it dispatches), falling back to the harness
name, with the workspace basename alongside as the tiebreaker for several
sessions driving the same repo. When the claude harness reports its own
`session_id` in the result envelope, kazi records it on the run row and the
slide-over panel shows the ready-to-paste resume command
(`claude -r <session-id>`), so any starmap node can be picked up
interactively.

**Clicking any canvas node — or an attention entry — opens the slide-over
drill-in panel** (docs/dashboard-design.md "Slide-over drill-in panel"): the
goal's identity chips (workspace, harness · model, state), its
iteration/budget burn bar, the predicate-vector DNA strip, the convergence
heatmap (predicates × iterations), and a transcript tail, plus a
"FULL ANALYST VIEW →" link to `/goals/:id/drillin`. It reads the same
projections the full-page drill-in and transcript-peek views read.

Click interactions (and live DOM patching generally) ride the LiveView
socket: the endpoint serves the pre-built `phoenix` / `phoenix_live_view`
client bundles straight from the hex packages (no node, no bundler) and the
root layout connects the socket. With JavaScript unavailable the pages
still render as read-only snapshots, exactly the pre-panel behavior.

On a phone (below 820px) the starmap re-flows into a bottom tab bar — MAP /
NEEDS YOU (with a live attention-count badge) / SESSIONS / MORE — the rail's
sections becoming thumb-reachable tab panes, the constellation panning at a
readable scale, and the drill-in panel opening as a full-width bottom sheet.
Desktop is untouched. See docs/dashboard-design.md "Mobile layout" for the
normative spec.

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

The roadmap's declared `needs` edges also draw as connector lines between the
placed nodes (highlighted cyan when either endpoint is converging or stuck),
so the canvas shows the same dependency structure `--explain` prints. Without
a roadmap there are no declared edges, so none are drawn — the flat fleet
fallback declares no order and the starmap never fabricates one.

`kazi dashboard --roadmap <goal-file>` (T47.2) wires a REAL goal-file into
this seam: it loads `<goal-file>` through `Kazi.Goal.Loader` — the same loader
`apply` uses — and points `GoalSource` at the loaded goal, so the starmap
renders ITS `needs`-DAG in wave bands. Only takes effect on a fresh standalone
boot; like `--port`/`--bind`, it is advisory (ignored, with a printed warning)
when this process already serves the endpoint. Absent the flag, `GoalSource`
stays `None` and the flat-list fallback is unchanged. A bad or unloadable path
is a loud boot error (a non-zero exit, nothing started) — never a silently
empty starmap. ADR-0056 §Decision 1 (a first-class roadmap read-model object,
written by a future plan-side surface) is still future work; today `--roadmap`
is the on-ramp, and `GoalSource` remains a seam a test can also point at any
`Kazi.Goal.t()` directly.

### The attention queue (T46.6)

Alongside the fleet list, a rail ranks what needs the operator right now —
`Kazi.Attention.Queue.build/2`, a pure projection over the SAME persisted
signals the per-goal detectors already compute:

| Signal                  | Severity | Fires when                                                                 |
| ------------------------ | -------- | --------------------------------------------------------------------------- |
| `stuck`                 | 4 (highest) | `Kazi.Loop.StuckDetector.stuck?/2` over the goal's `iteration_history/1`: N consecutive observations share the same non-empty failing set. |
| `budget`                | 3        | the run's declared `max_iterations` (captured at registration, T46.6) is >= 85% consumed by its observed iteration count. |
| `flake_suspicion`       | 2        | some predicate's claim-bearing status has flipped at least twice across the history -- nondeterministic-looking, even though no detector has quarantined it. |
| `regression_recovered`  | 1 (lowest) | `Kazi.ReadModel.regressions/1` recorded a green→red flip whose predicate is back to `:pass` as of the latest observation. |

Entries are ranked by severity, ties broken by recency (the triggering
iteration index, most recent first) then `goal_ref` -- a fully pinned order.
Each entry deep-links to that goal's `/goals/:id/drillin`. An empty fleet (or
a fleet with nothing to flag) renders no rail. See `Kazi.Attention.Queue` and
`KaziWeb.StarmapLive`.

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
truncated transcript apart from a torn one. `Kazi.Sink.Transcript.read/1`
tails a sink file back into decoded maps (dropping a torn final line), the
same contract as `Kazi.Sink.Events.read/1` -- the reader the transcript peek
view below polls.

## The drill-in convergence heatmap (`/goals/:id/drillin`, T46.7)

Per-goal, below the full history timeline (`/goals/:id/history`): a
**predicates x iterations matrix** built straight from
`Kazi.ReadModel.list_iterations/1` — one row per predicate id (the union seen
across the goal's whole history, so a predicate introduced mid-run still gets
a row), one column per iteration oldest-to-newest, each cell that predicate's
status at that observation (`pass`/`fail`/`error`/`unknown`, or
`not_evaluated` for an iteration before the predicate existed). The newest
column is marked **current**; a green→red regression flip
(`Kazi.Loop.RegressionDetector`, T1.2) is marked `regression-flip` on the exact
cell where it was first observed, so a pinned green→red→green run is visually
distinct from ordinary outstanding work in the same row.

Clicking a column header (the **scrubber**) selects that iteration; the detail
panel below then shows that iteration's full predicate vector (id + status),
its dispatch action (`action_kind`, when the loop dispatched), and the
ADR-0046 context/tool counters (`tool_calls`, `file_reads`,
`orientation_tokens`, `evidence_tokens`, `tier`). With nothing scrubbed the
panel follows the current (latest) iteration live, matching the matrix's
current-column marker. See `KaziWeb.DrillinHeatmapLive`.

## The transcript peek (`/runs/:run_id/transcript`, T46.8)

Per-run: tails the run's `transcript.jsonl` (`Kazi.Sink.Transcript`). There is
exactly **one code path** for a live run and a finished/dead one -- `mount/3`
resolves the run (`Kazi.ReadModel.RunRegistry.get/1`) and reads its sink fully,
so opening a terminal run's transcript renders the whole thing immediately
with no watcher required; a connected mount additionally polls on a short
interval and reloads the sink when a growing file has new lines to tail in
(for a finished run the file never grows, so the same poll is simply a no-op).

Tool-shaped events (a `"type"` starting with `"tool"`, e.g. `tool_use` /
`tool_result`) collapse to a one-line pill (the tool name); clicking a pill
expands it to its full JSON payload. A `{"type": "truncated"}` marker (the
transcript sink's size-cap event) renders as an explicit notice rather than
folding or silently vanishing. The **follow** toggle pauses/resumes picking up
newly tailed lines without discarding what's already rendered. See
`KaziWeb.TranscriptPeekLive`.

## The event river (`/events`, T47.1)

A single fleet-wide feed of every registered run's `events.jsonl`, newest
first (bounded to the 100 most recent entries across the whole fleet): each
entry is one loop observation, tagged with its goal ref and run id, with
deep links to that run's transcript peek and that goal's drill-in. A run
with no events sink (not persisted) or an unreadable/missing sink file
contributes zero events rather than erroring the feed; a torn final line is
dropped the same way `Kazi.Sink.Events.read/1` already tolerates it
everywhere else. A connected mount polls (2s) and rereads every run's sink,
so a newly appended event appears on the next tick with no restart. An empty
fleet renders an honest empty state. See `KaziWeb.EventRiverLive`.

## `kazi dashboard`

```
kazi dashboard [--port <n>] [--bind <ip>] [--roadmap <goal-file>]
```

Boots the web endpoint standalone — **no goal loop in the process** — against
the shared read-model + run registry, localhost-bound by default
(`127.0.0.1`); pass `--bind` explicitly to listen on a non-loopback address.
`--port`/`--bind`/`--roadmap` apply to a **fresh** standalone boot; if this
process already supervises the endpoint (the normal dev-server / `mix
kazi.apply` / test entry points), the verb reports the endpoint's existing
bind instead of rebinding it, and `--roadmap` is ignored (printed, never
silent).

`--roadmap <goal-file>` (T47.2) loads that goal-file and renders its
`needs`-DAG as the starmap's wave bands (see "Wave bands" above) — the first
user-visible consumer of `KaziWeb.Starmap.GoalSource`. An unloadable path
(missing file, malformed TOML, a schema violation) is a loud boot error: kazi
prints the reason to stderr and exits non-zero without starting the endpoint,
never a silently empty starmap.

A standalone boot serves **every** dashboard view (`/`, `/starmap`, `/goals`,
`/leases`, `/dag`, `/goals/:id/history`, `/goals/:id/drillin`,
`/runs/:run_id/transcript`, `/events`), with web-tree parity to the full
app's supervision tree: views whose live source has nothing to show (no
active run registered in this node) render their honest empty state, never a
500 (issue #801).

## Retention and scope

Single-machine scope for now: the shared SQLite read-model requires zero new
infrastructure. Cross-node fleets and the NATS fan-in stay Slice 3
(ADR-0057 §5) — this dashboard becomes that slice's first real consumer when
it arrives.

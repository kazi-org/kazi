# Velocity data — the delivery-event projection (T67.2, ADR-0079)

The velocity surface (E67) answers "how fast are my agents delivering?" from data
kazi already has, with **no GitHub call at render time**. Its first building
block is the **delivery-event projection**: a pure read projection (ADR-0011 §2)
that scans a workspace's git history and records one row per delivery fact into
the `delivery_events` read-model table, written only through the daemon
single-writer (ADR-0068).

## What it derives

`Kazi.ReadModel.DeliveryProjection.project(workspace, opts)` scans every commit
that touches `docs/plan.md` / `docs/plans/*.md` (in the requested range) and
records:

- **`:task_tick`** — one row per added `- [x] TNN ... Done: <date> (PR #N)` plan
  line, carrying the task id, its epic (from the plan file path), the `Done:`
  date, and the PR the line names.
- **`:pr_merge`** — one row per distinct PR number a commit lands, carrying the
  PR number, the landing commit sha, and the merge time.

Each row also carries `repo_slug` (`org/repo`, from the workspace's git `origin`
remote), for fleet grouping. See `Kazi.ReadModel.DeliveryEvent` for the full
column set (all the join keys ADR-0079 §3 names).

## Session attribution — honest by construction (ADR-0079 §1)

The authoritative delivery→session spine is the **run registry**, not the commit
trailer. A git-derived tick carries no `goal_ref`, so on a trailer-stripped repo
(like kazi's own) `session_uuid` is `nil` — an honest **fleet-level** row
(ADR-0046), never guessed from timing. The run-registry join
(`goal_ref` → `run.harness_session_id`) is applied wherever a `goal_ref` is known
for a delivery; it is the query-time join the KPI layer (T67.4) leans on.

### The `Claude-Session:` commit-trailer grammar (optional enrichment)

A commit MAY carry a trailer line of the form:

```
Claude-Session: https://claude.ai/code/session_<id>
```

where `session_<id>` is an opaque token (`session_` followed by URL-safe
characters: letters, digits, `._~-`). The projection captures that `session_<id>`
token verbatim into the **nullable, optional** `trailer_session_id` column.

**This repo strips the trailer before push** (the standing commit-hygiene rule),
so it is absent on kazi's own history and the enrichment yields nothing here — by
design, not a bug. `trailer_session_id` exists for repos that *keep* the trailer;
it is never a required join key (ADR-0079 §1 rejects the trailer as the primary
join precisely because kazi strips it).

## Idempotency & incrementality

- **Idempotent.** Each row upserts on a composed `dedup_key`
  (`kind|task_id|pr_number|merge_commit_sha`, with `""` sentinels for the nullable
  parts) via `on_conflict: :nothing`. Re-scanning the same history produces each
  row exactly once — same history in, same rows out.
- **Incremental.** `project/2` accepts `:since` (a commit-ish) to bound the git
  log to `<since>..HEAD`. `last_seen_commit/0` returns the newest already-projected
  landing commit, so a caller can scan only what is new.

## Boundaries

- No network: every fact is derived from local commit history alone.
- No loop coupling: reads only, writes only through the daemon (ADR-0068); the
  socket seam is pinned by `test/kazi/read_model/delivery_projection_socket_test.exs`.
- No completion estimate: the schema has no ETA/estimate column (ADR-0079 §3), so
  a fabricated date is unrepresentable at the storage layer.

# Velocity KPIs — the query module (T67.4, ADR-0079 §4)

`Kazi.Velocity.Kpis.compute/1` reads the two projections above joined with the
run registry (`Kazi.ReadModel.Run`) and returns a `%Kpis{}` of RATES, RATIOS, and
one duration DISTRIBUTION — never a date or completion estimate. It is a pure read
(ADR-0011): no writes, no loop coupling, no network. Options: `:window_days`
(trailing window width, default `7`) and `:now` (window upper bound, default
`DateTime.utc_now/0`); deliveries with an instant in `(now - window_days, now]`
count.

Honest-unknown (ADR-0046) throughout: insufficient data yields `nil` ("not enough
data yet"), never a `0` masquerading as a measurement, and an empty window never
divides by zero. The struct — and every nested struct (`Agent`, `ModelStuck`,
`Distribution`) — carries **no** ETA/estimate/projected-completion field, so a
future UI cannot render one; `test/kazi/velocity/kpis_test.exs` asserts that
absence at the type layer.

| KPI | definition | source |
|---|---|---|
| **delivered / day** (fleet + `per_agent`) | `:task_tick` deliveries in the window ÷ `window_days`, to 2dp. A tick's instant is `merged_at`, else its `Done:` date at UTC midnight. A measured `0.0`/day (window happened, nothing landed) is real, not unknown. | `delivery_events` |
| **tokens per delivered task** (fleet + `per_agent`) | cumulative session tokens (sum of the five non-nil `session_counters` token fields) ÷ delivered tasks in the window, to 1dp. `nil` when nothing delivered (no division) or the session exposed no token counter at all. | `session_counters` ÷ `delivery_events` |
| **stuck ratio** (`per_agent` + `stuck_by_model`) | `(stuck + over_budget) ÷ total terminal verdicts`, to 3dp, over FINISHED runs (`finished_at` set). `nil` for a session/model with no terminal run. Per-model buckets use the same `ModelIdNormalization.normalize/1` as `kazi economy`. | `runs` |
| **rescue count** | lanes (goal_refs) whose terminal `converged` run's session differs from the session that first claimed the lane (earliest `started_at` run). Run-registry only, since claims themselves are ephemeral git refs. | `runs` |
| **claim → merge lead time** | a p50/p90 duration DISTRIBUTION (seconds), NOT a promised ETA. Per delivery with an attributed session and a merge instant, `merged_at − claim`, where the claim is the latest `started_at` of a run by that session not after the merge. Deliveries with no joinable claim contribute no sample. Nearest-rank percentile — the same method as `kazi economy`. | `delivery_events` ⋈ `runs` |

## Reconciliation with `kazi economy`

The per-model split draws its terminal universe from the SAME finished-runs
population `Kazi.Economy.History.aggregate/1` groups (`finished_at` not nil) and
buckets `model` through the SAME normalizer, so the per-model terminal counts
reconcile with economy's group sizes rather than forking a second cost/outcome
truth — pinned in `kpis_test.exs`.

# The dashboard velocity panel (T67.5, ADR-0079)

The KPIs above render on the operator dashboard (Mission Control, `/`) as a
**fleet velocity strip** plus a **per-agent drill-in**. It is an *operator*
surface — present in both the operator and `?debug=1` modes (unlike the
DAG/lease-map/event-river expert surfaces, which are debug-only per ADR-0078,
T63.7) — and it reuses T63.9's progress-rate vocabulary so the two panels read as
one system: every figure is a **rate, ratio, or measured historical
distribution**, and there is deliberately no date, ETA, or completion-estimate
copy anywhere (ADR-0046). `assign_velocity/1` in
`lib/kazi_web/live/mission_control_live.ex` calls `Kazi.Velocity.Kpis.compute/1`
each poll tick; it is a read-only projection (ADR-0011) that renders the honest
empty state rather than a 500 if the read-model is unavailable.

## The strip

Four cards over the trailing window (labelled, e.g. "last 7d"):

| card | copy | honest-unknown |
|---|---|---|
| **DELIVERED** | `<per_day> /day · <count> in last 7d` | — |
| **TOKENS / TASK** | `<tokens> tok/task` (compact, e.g. `5.5k`) | `— not enough data yet` when no delivery or no token counter |
| **STUCK RATIO** | `<pct>% stuck · <stuck>/<terminal> terminal` (the fleet terminal-verdict population, aggregated across the per-model split) | `— no terminal runs yet` |
| **CLAIM → MERGE LEAD** | `p50 <dur> · p90 <dur> · <n> samples` — a measured span of *past* deliveries, never a promise | `— not enough data yet` when no joinable sample |

Durations are compact spans (`1h 23m`, `45s`) of already-merged deliveries, not a
countdown; they are historical measurements, not an ETA.

## Insufficient-data edge (R-E67-4)

A fresh fleet with **no** delivery, session counter, or terminal run in the window
renders an explicit **"Not enough data yet"** message (`#mc-velocity-empty`)
instead of the strip — zeros are never presented as measurements. Velocity appears
only once the fleet actually ships.

## Per-agent drill-in

Below the strip, one expandable (`<details>`) per session shows that agent's
delivered/day and stuck ratio at a glance; expanding it **names the offending
stuck goals** — the `goal_ref`s whose runs went `stuck`/`over_budget`, attributed
from the run registry (the same terminal-verdict universe the stuck ratio counts,
the attribution `kazi economy` reads — not a second truth). A high stuck ratio thus
points the operator at *which* lane needs attention, not just a number.

Certified by `test/kazi_web/live/mission_control_live_test.exs` (seeded-KPI render
with the rate-labeled copy + no-ETA negative assertion, the insufficient-data
edge, and the operator/debug mode presence) and
`test/playwright/mission_control_velocity.spec.ts` (the golden path and the
insufficient-data edge in a real browser).

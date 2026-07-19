# ADR-0079: Velocity data architecture — agent-delivery linkage, the session-stats collector boundary, the read-model schema, and rate-only display rules

## Status

Accepted

## Date

2026-07-19

## Context

The operator asked to "see the velocity of my Claude agents — delivered tasks,
tokens consumed, stuck stats" as a first-class DASHBOARD surface, built right
once (E67). The scope decision is FULL FUSION: the surface must cover BOTH agent
populations —

1. **kazi-driven runs**, already instrumented in the read-model (iterations,
   verdicts, per-run token KPIs via `Kazi.ReadModel.Run`, `kazi economy`
   percentiles), and
2. **interactive harness sessions** (a human driving Claude Code / Codex
   directly), whose activity today lives only in local transcript JSONL outside
   kazi.

Population 2 needs new plumbing: a way to attribute a session's delivered work
(ticked plan tasks, merged PRs) and its resource spend (tokens, messages,
active time) to one durable agent identity, without exporting any transcript
CONTENT off the machine.

Everything downstream (T67.2 git-derived delivery projection, T67.3 session
collector, T67.4 KPI queries, T67.5 panel, T67.6 live dogfood) is gated on the
decisions recorded here. This ADR is deliberately decisive — one option per
decision — because six tasks hang off it.

The design operates under four frozen constraints, named here so every task
inherits them:

- **ADR-0011 (read-only projection).** Operator surfaces are READ projections
  over existing state; they never couple into the core loop
  (`docs/adr/0011-slice3-operator-surfaces.md` §2). The velocity surface adds
  projection tables and read queries only — no control path, no loop coupling.
- **ADR-0046 (honest-unknown / rate-only economy).** Absent data is surfaced as
  explicit unknown, never coerced to `0` (the discipline already enforced on
  `Kazi.ReadModel.Run`'s token/cost fields, `lib/kazi/read_model/run.ex:59-61`).
  Every velocity number is a rate or ratio, never a date or completion estimate.
- **ADR-0068 (daemon single-writer).** When `kazi daemon` runs it is the only
  process that opens the read-model read-write; all new writes route through its
  Unix-domain-socket API. Cheap reads may stay direct on WAL
  (`docs/adr/0068-daemon-single-writer-read-model.md`).
- **ADR-0067 (session-coordination bus).** Cross-machine facts ride the existing
  JetStream bus primitives; convergence never depends on the bus. The velocity
  collector reuses the `fact` primitive (last-value-per-subject), the same one
  T60.1's run mirror already uses — not a second transport.

## Decision

### 1. Linkage model — the "agent delivery" identity

**The spine is the immutable session UUID, and the authoritative join fabric is
the run registry — NOT the commit trailer.**

Per E65 (`docs/plans/E65.md:14-22`), identity is the immutable session UUID;
the durable *name* is a daemon-assigned alias bound to that UUID in JetStream KV.
The UUID resolves from `CLAUDE_CODE_SESSION_ID` / `KAZI_SESSION_NAME` /
`--session-name` (`lib/kazi/bus.ex:20-23`). We adopt this UUID as the single
canonical key for an "agent delivery" identity. `session_name` is a *display
alias* only, resolved through E65's KV at render time; it is never a join key
(a rename must not fork an agent's history).

**Join keys that exist TODAY** (all in `lib/kazi/read_model/run.ex`, the runs
schema, whose sole writer/reader is `RunRegistry`, `run_registry.ex:14-16`):

| edge | join key(s) that exist today | anchor |
|---|---|---|
| session → run | `run.harness_session_id` (the harness `session_id`), `run.session_name` | `run.ex:41-42`, written by `record_harness_session/2` (`run_registry.ex:113-141`) |
| run → goal | `run.goal_ref` | `run.ex:22` |
| run → proposal | `run.proposal_ref` | `run.ex:48` |
| run → economics | `run.dispatch_count`, `run.budget_tokens`, `run.budget_cached_input_tokens`, `run.budget_cost_usd` | `run.ex:62-66` |
| run → terminal outcome | `run.status`, `run.outcome_cause_class` | (verdict source for stuck ratio) |
| task tick → PR | `TNN` task id + `Done: <date> (PR #N)` in `docs/plans/ENN.md` | plan-tick convention (CLAUDE.md "Plan layout") |

For **population 1 (kazi runs)** this fabric is complete today: a session's UUID
(`harness_session_id`) joins to its runs, each run to its goal and its per-run
token/cost/dispatch KPIs and terminal verdict. No new field is required to
attribute kazi-run velocity to a session.

For **population 2 (interactive sessions)** the delivery signal is git-derived —
a ticked plan task and the PR that merged it. The join from a delivered task
back to a *session* is the crux, and here we record a hard, honest constraint:

> **The `Claude-Session:` commit trailer is NOT a reliable in-repo join key for
> the kazi repository.** The trailer (`Claude-Session: https://claude.ai/code/
> session_<id>`) is a harness/global convention with **no definition anywhere in
> this repo** (grep finds zero occurrences), and — critically — this repo's
> commit hygiene *requires stripping* that trailer before pushing (CLAUDE.md /
> the standing worker rules). So kazi's own merged commits carry no session
> trailer, and a linkage design that depends on it would silently attribute
> nothing on the very repo it runs in (the #1483 "plausible surface over empty
> tables" failure class).

Decision, therefore:

- **Primary delivery→session join is the run registry, not the trailer.** A
  merged PR that ticked `TNN` is attributed to a session when a run for that
  PR's goal exists (`run.goal_ref` ↔ the goal the PR shipped, and
  `run.harness_session_id` ↔ the session). This covers all kazi-driven delivery
  with keys that exist today.
- **The commit trailer is an OPTIONAL enrichment for trailer-bearing repos**, not
  kazi's. Where a repo *does* keep the trailer, T67.2 MAY parse
  `trailer_session_id` out of the merge-commit chain as an additional
  delivery→session key. This is named as a **new, explicitly-optional field**
  (`delivery_events.trailer_session_id`, nullable), never a required one, and its
  format spec (the `Claude-Session:` grammar) must be documented in-repo by
  T67.2 since it is undocumented today.
- **Unattributable delivery is attributed at FLEET level, never fabricated.** A
  ticked task with no run and no trailer (e.g. a purely interactive commit on
  the kazi repo) counts toward fleet delivered-rate but carries a `nil`
  `session_uuid` — honest-unknown (ADR-0046), never guessed from timing.

The "agent delivery identity" is thus: **the session UUID as spine, with runs,
goals, economics, terminal verdicts, ticked tasks, and merged PRs hanging off it
via the keys above; delivery that cannot be joined to a UUID is fleet-level and
explicitly unattributed.**

### 2. Collector boundary — what it reads, what it emits, how it ships

**A per-machine, opt-in session-stats collector that reads local transcript
JSONL and emits ONLY schema'd aggregate counters, shipped as bus facts through
the daemon write path.**

- **Reads:** the local harness session transcript JSONL only. All knowledge of
  the transcript format is confined to this collector edge (R-E67-1); a format
  break degrades to "no new rows" plus a surfaced warning — never a crash, never
  a wrong number.
- **Emits — a closed whitelist of aggregate counters, keyed by session UUID:**
  `input_tokens`, `cached_input_tokens`, `cache_write_tokens`, `output_tokens`,
  `reasoning_tokens`, `message_count`, `tool_call_count`, and `active_time_s`
  bucketed into fixed-width time buckets, plus `first_observed_at` /
  `last_observed_at`. **NEVER** transcript content, prompt/response text, tool
  *names*, file paths, or any free-text label (R-E67-3). The counter field set
  reuses ADR-0046's cached-vs-fresh token split so it reconciles with
  `run.budget_*` and `kazi economy`. Honest-unknown: a counter the transcript
  does not expose is emitted `nil`, never `0`.
- **Ships cross-machine by riding the T60.1 bus-mirror pattern, not a second
  transport.** The collector posts a session-counter **`fact`** (ADR-0067
  last-value-per-subject) on topic **`session:<short-uuid>`**, mirroring the run
  mirror's `run:<short-run-id>` topic (`Kazi.Runtime.BusMirror`,
  `lib/kazi/runtime/bus_mirror.ex:27-28,167-168`). Because the counters are
  **cumulative** and the `fact` primitive keeps only the last value per subject,
  a re-post idempotently overwrites the session's current totals — duplicate
  ships collapse to one current row by construction. The daemon consumes the
  fact and performs the read-model write (ADR-0068); no writer bypasses the
  daemon.
- **Idempotency / incremental cursor:** the collector keeps a local per-transcript
  cursor (byte/line offset). Each pass parses only bytes past the cursor and adds
  to the cumulative counters, then advances the cursor. Same transcript in ⇒ same
  totals out; a re-scan from a persisted cursor produces identical rows. The
  cursor is machine-local state, not read-model state.
- **Opt-in switch:** the collector is **disabled by default** and enabled only by
  an explicit per-machine config/flag (a `[velocity]`/collector setting, plus a
  `KAZI_VELOCITY_COLLECTOR` env override), documented in the same PR that adds it
  (ADR-0034). No transcript is read on a machine that has not opted in.

### 3. Read-model schema — delivery events + session counters

**Two new projection tables (ADR-0011 read projections; ADR-0068 daemon-written),
both joinable to the run registry on the session UUID. No ETA/estimate column
exists in either.**

**`delivery_events`** — one row per git-derived delivery fact (a plan tick and/or
its merged PR), incremental by last-seen commit SHA, idempotent on re-scan:

| field | purpose / join |
|---|---|
| `id` | surrogate PK |
| `kind` | `:task_tick` \| `:pr_merge` |
| `task_id` | the `TNN` id ticked (nullable for a PR that ticked none) |
| `epic` | `ENN` the task belongs to |
| `done_on` | the `Done:` date from the plan tick |
| `pr_number` | the merging PR (nullable) |
| `merge_commit_sha` | the merge/rebase commit (dedup + incremental cursor) |
| `merged_at` | merge timestamp (lead-time input) |
| `repo_slug` | `org/repo` (fleet grouping) |
| `session_uuid` | **nullable** — the attributed session (via run registry; see §1). `nil` = honest fleet-level-only |
| `goal_ref` | the goal the delivery shipped, when a kazi run backs it (nullable) |
| `trailer_session_id` | **nullable, optional** — parsed from a `Claude-Session:` trailer only where the repo keeps it (§1); never required |

Uniqueness/idempotency: a `(kind, task_id, pr_number, merge_commit_sha)` key so
repeated scans of the same history produce each row exactly once (T67.2 acc).

**`session_counters`** — one row per session UUID, last-write-wins from the
collector's cumulative fact:

| field | purpose / join |
|---|---|
| `session_uuid` | PK; joins to `run.harness_session_id` |
| `session_name` | display alias at last observation (never a join key) |
| `machine` | which host produced the counters (collector opt-in is per-machine) |
| `input_tokens`, `cached_input_tokens`, `cache_write_tokens`, `output_tokens`, `reasoning_tokens` | cumulative token counters (ADR-0046 split); `nil` when unexposed |
| `message_count`, `tool_call_count` | cumulative event counters |
| `active_time_s` | cumulative active-time seconds (bucketed at the edge) |
| `first_observed_at`, `last_observed_at` | window bounds for rate denominators |

Both tables are written ONLY through the daemon write op (ADR-0068), asserted in
T67.2/T67.3 via the socket seam. Reads are direct projections (ADR-0011). Neither
table has a projected-completion, ETA, or "estimated finish" column — the schema
makes a fabricated date unrepresentable (R-E67-2 at the storage layer).

### 4. Display rules — rate/ratio-only vocabulary, reusing T63.9

**Every velocity number is a rate, a ratio, or a distribution, labeled with its
window and its source. No completion date or duration promise is ever computed,
stored, or rendered — the same discipline T63.9's progress-rate panel already
ships.**

The KPI vocabulary (computed by T67.4, rendered by T67.5):

- **delivered / day** — `delivery_events` per trailing window (label the window,
  e.g. "last 7d"); per-session and fleet-level.
- **tokens per delivered task** — `session_counters` tokens ÷ delivered tasks in
  the window (a ratio, not a projection).
- **stuck ratio** — `(stuck + over_budget terminal verdicts) ÷ total terminal
  verdicts`, per session and per model, from `run.status`.
- **rescue count** — lanes closed by a different session than claimed (a count).
- **claim → merge lead time** — reported as a **duration DISTRIBUTION (p50/p90)**,
  never a single promised ETA; this reuses `kazi economy`'s p50/p95 percentile
  idiom (`lib/kazi/cli.ex:9484-9505`) and reconciles with it rather than forking
  a second cost/latency truth (E67 Notes).

These reuse **T63.9's flip-velocity vocabulary verbatim** in spirit
(`Kazi.ReadModel.goal_progress_rate/1`, ADR-0046): a rate is `N.N /<unit>`;
insufficient data yields an honest `nil` ("not enough data yet"), never a
fabricated `0` presented as a measurement (R-E67-4). The T67.4 KPI struct
exposes **no** projected-completion field at all, so a future UI cannot
accidentally render one — the negative assertion T63.9 pins at the render layer
is here pinned at the *type* layer.

The panel lives in the **OPERATOR** mode surface and respects T63.7's
operator/debug mode split (ADR-0078), so it reads as one system with the
existing progress-rate panel.

## Consequences

- The velocity surface is buildable on join keys that exist today for the entire
  kazi-run population; interactive-session attribution is honest about its limits
  (fleet-level when no UUID join exists) rather than fabricating attribution from
  a trailer this repo strips.
- The collector cannot leak content: the wire payload is a closed counter
  whitelist, pinned by T67.3's payload-shape test. Anything outside the schema
  fails the test.
- All writes flow through the daemon (ADR-0068); no second transport and no
  second cost truth (`kazi economy` stays authoritative; T67.4 reconciles).
- A fabricated completion date is unrepresentable at the schema and KPI-struct
  levels, not merely discouraged at the render layer.
- Cost: two new projection tables and a per-machine collector to maintain, plus
  an in-repo spec for the `Claude-Session:` trailer grammar (owed by T67.2) if
  the optional trailer enrichment is ever exercised.

## Alternatives considered

- **Commit trailer as the primary session join.** Rejected: undocumented in-repo
  and actively stripped by this repo's commit hygiene, so it would attribute
  nothing on the kazi repo itself — a plausible-but-empty surface (#1483). Kept
  only as an optional, nullable enrichment for repos that retain it.
- **A second transport for session stats (dedicated socket / HTTP push).**
  Rejected: violates the "ride the existing bus, one write path" constraint
  (ADR-0067/0068); the `fact` primitive already gives idempotent last-value
  shipping for free.
- **Shipping per-message or per-tool detail for richer drill-in.** Rejected:
  cannot bound content leakage (tool names, file paths); the aggregate-only
  whitelist is the privacy boundary (R-E67-3). Drill-in richness comes from
  joining to the *already-present* run/economy data, not from the transcript.
- **Deriving an ETA from delivered/day.** Rejected outright by ADR-0046; the KPI
  struct omits the field so it cannot be rendered by accident.

## Cross-references

- **E63 / T63.7** — the velocity panel lives in the operator-mode surface this
  epic's mode split (ADR-0078) defines.
- **E63 / T63.9** — the rate/ratio display vocabulary and the honest-`nil`
  insufficient-data rule are reused from `goal_progress_rate/1`.
- **E65** — the session UUID identity spine and the daemon-assigned name alias.
- **E60 / T60.1** — the `BusMirror` fact-shipping pattern the collector rides.
- **ADR-0058 / `kazi economy`** — the authoritative percentile cost surface the
  lead-time distribution reconciles with, never forks.

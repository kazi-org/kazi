# T63.4 — Operator-questions information architecture proposal

Status: PROPOSAL (David reacts per E63's Wave-A gate; not yet implemented).
No production code changed by this task. Composite mock: `composite.html` in
this directory.

## The four standing questions, each with a named answering surface

### Q1 — "What is my fleet working on?"

**Answering surface: the existing Mission Control fleet grid**
(`lib/kazi_web/live/mission_control_live.ex`), extended by T60.1's
cross-machine run facts.

- Every goal's card state — `:landed` / `:stuck` / `:stale` / `:converging`
  — is already a pure projection of `Kazi.ReadModel.RunRegistry` (see the
  module doc, lines 14-22). `budget_tokens`/repo/project labels already
  render (line 56, `project_label/1`).
- **Gap, already flagged and owned:** `assign_fleet/1` (mission_control_live.ex:186)
  reads `RunRegistry.list()` LOCAL-ONLY today — a goal running on a different
  machine doesn't appear. T60.1 (PR #1380, merged) now posts run-lifecycle
  facts to the bus; T60.1's own acc explicitly calls for the starmap to
  "render a run from a different machine distinctly" — that's the remaining
  clause 3 follow-up already on the board (`~/.claude/bus/kazi/coordination.md`,
  "FOR kazi-a" note), not new scope this task invents.
- No new field required once that follow-up lands — this question is
  answered by data that already exists.

### Q2 — "Where can I help?"

**Answering surface: `Kazi.Attention.Queue.build/2`** (`lib/kazi/attention/queue.ex`),
made trustworthy by T63.1's heartbeat gate, extended fleet-wide by T60.3.

- The attention queue already ranks exactly this question by construction —
  its five signals (`:cause` severity 5, `:stuck` 4, `:budget` 3,
  `:flake_suspicion` 2, `:regression_recovered` 1; see the module doc) are a
  pure read of existing detectors (`Kazi.Loop.StuckDetector`, the read-model's
  `regressions/1`, `max_iterations` vs. observed iteration count). Nothing
  here is fabricated — every entry traces to a persisted signal.
- **Gap 1 (T63.1's job, in this epic, Wave A):** today the queue ranks over
  ALL registry runs including heartbeat-stale ghost `running` rows (#1155)
  — T63.1 gates the queue's input on freshness so a phantom never ranks.
  This proposal assumes T63.1 lands; it does not re-scope T63.1's fix.
- **Gap 2 (T60.3's job, separate epic):** the attention queue as it exists
  today answers "what's wrong with a RUN" (stuck, over-budget, regressed).
  It does NOT answer "what session is blocked waiting on a human RIGHT NOW"
  (a permission prompt, a question) — that is a different signal class
  (session-level, not run-level) that T60.3 is scoped to add via a NEW bus
  fact kind (see reconciliation section below). "Where can I help" on the
  dashboard should ultimately fan in BOTH: T63.1's truthful run-attention
  queue AND T60.3's blocked-session facts, as two sections of one surface —
  neither replaces the other.

### Q3 — "What is blocking them?"

**Answering surface: the attention queue's `detail` map, surfaced verbatim
instead of just a count.**

- Every attention-queue entry already carries a `signal` (the blocker CLASS
  — cause/stuck/budget/flake/regression-recovered) and a `detail` map with
  the triggering `predicate_ids` (queue.ex `@type entry`). A `:cause` entry
  in particular carries a `Kazi.Loop.CauseClass` terminal cause of
  `"error_wedged"` / `"quarantine_blocked"` / `"capability_unreachable"` —
  i.e. the read-model ALREADY names the specific blocker, not just "stuck".
- **Current gap:** nothing upstream of this proposal renders that detail —
  it exists in the data model but Mission Control today shows state chips
  (`:stuck`), not the blocker's name. The IA fix here is presentational:
  render `entry.signal` + `entry.detail` inline wherever a blocked run
  appears (fleet card, attention section, drill-in), instead of a bare
  "stuck" badge. No new read-model field — the objective source already
  names the blocker; the gap is that today's UI collapses it to a status
  word.

### Q4 — "How much longer until projects complete?" (the tricky one)

**Answering surface: rate/progress displays only, never a date — ADR-0046
honest-unknown is a hard rule here, not a preference.**

Three objective, already-computable displays, each cited to its source:

1. **Predicates green vs. total, per goal** — `kazi status <ref> --json`'s
   `predicates[]` array (verified live against `runtime-gherkin-provider-adr-0071-loader`
   while building T63.3's mocks: 3 of 8 predicates pass today). Source:
   `Kazi.ReadModel` current predicate vector, already exposed via `kazi status`
   and the goal-board LiveViews.
2. **Red→green velocity over recent iterations** — derivable from
   `Kazi.ReadModel.Iteration.regressions` (T1.2) across
   `Kazi.ReadModel.list_iterations/1`'s history: count of flips per N
   iterations. Same data source T63.3's drill-in/history mocks already use
   for flip detection — no new field, a client-side diff over existing rows.
3. **Budget consumed vs. cap** — `Run.max_iterations` (T46.6, already read
   by the attention queue's `:budget` signal) against the observed iteration
   count from `list_iterations/1`. Already partially rendered as
   `budget_tokens` on the Mission Control card (mission_control_live.ex:56).

**Explicit rule for this section's copy:** every one of the three displays
above is labeled as a RATE or a RATIO ("3/8 predicates passing", "2 flips in
the last 4 iterations", "62% of iteration budget used") — never as "ETA: 2
hours" or any phrasing that implies a promised date. If a future task wants
a projected completion time, it needs a NEW ADR justifying the extrapolation
method and its honesty framing; this proposal explicitly does not authorize
one.

## "Less intimidating" — operator / debug mode split

Default view ("operator" mode) shows: the fleet grid (Q1), the attention
queue (Q2/Q3 merged — signal + blocker inline), and the three rate displays
(Q4) — nothing else. A "debug" mode toggle (a single link/switch, not a
separate route) reveals the existing expert surfaces unchanged: the DAG
view, the event river, the lease map. This is a presentational filter over
EXISTING routes/components, not a new data model — nothing here requires a
new read-model query beyond what Q1-Q4 already cite. Scoping the actual
toggle implementation is left to T63.5 (this task is the proposal, not the
build).

## Reconciliation with E60 T60.3 / T60.4 (who ships what)

This epic (E63) and E60 both touch "what needs my attention" and "portfolio
state" — explicit split so they land as ONE coherent surface, not two:

- **T60.1** (E60, already merged as PR #1380): ships the cross-machine BUS
  FACT plumbing — run lifecycle events posted so a fleet's activity is
  visible across machines. T63.4 (this doc) treats T60.1's output as a
  data source for Q1, does not re-implement it.
- **T60.3** (E60, open): ships the SESSION-level "waiting on human" bus fact
  + board filter (per issue #1156) — a different signal class from the
  RUN-level attention queue T63.1 fixes. T63.4's Q2 answering surface is
  explicitly BOTH sections composed together (run-attention + blocked-
  session), not a merge of the two into one list — they have different
  identities (a run vs. a session) and different lifecycles (a run's
  attention entry clears when the run's state changes; a blocked-session
  fact clears when the human responds). T63.5 should compose them as two
  labeled sub-sections under one "where can I help" heading, not interleave
  them into a single undifferentiated feed.
- **T60.4** (E60, open, depends on T60.1): ships the PORTFOLIO bucket view
  (planned/in-progress/stuck/complete, per-repo and fleet-wide) built purely
  from kazi's own objective surfaces (`list-proposed` for planned, run
  registry for in-progress/stuck/complete). T63.4's Q1 (fleet grid) and
  T60.4's portfolio buckets are COMPLEMENTARY, not duplicative: the fleet
  grid is a live, per-run view (what's happening right now); the portfolio
  view is a rolled-up, per-goal-lifecycle-stage summary (has this proposal
  even started yet). T63.5 should link them (a portfolio "in progress"
  bucket entry navigates to that goal's fleet-grid card / drill-in), not
  reimplement one inside the other.
- **Net split:** T60.1/T60.3/T60.4 ship the DATA plumbing and their own
  dedicated views (bus facts, blocked-session board, portfolio buckets).
  T63.4/T63.5 own the DASHBOARD-LEVEL composition — arranging those existing
  and in-flight surfaces into the operator/debug split and the four-question
  IA described above. Neither epic re-implements the other's data source.

## Gap summary (every element above, source or gap)

| Question | Element | Source | Gap? |
|---|---|---|---|
| Q1 | Fleet grid, per-goal state | `Kazi.ReadModel.RunRegistry` via `assign_fleet/1` | Cross-machine rendering — T60.1 clause 3, flagged, unclaimed |
| Q2 | Run-level attention ranking | `Kazi.Attention.Queue.build/2` | Needs T63.1's freshness gate (this epic, Wave A) |
| Q2 | Session-level "blocked on human" | none yet | T60.3, open (E60) |
| Q3 | Blocker name (not just "stuck") | `entry.signal` + `entry.detail` (already in queue.ex) | Presentational only — render what already exists |
| Q4 | Predicates green/total | `kazi status --json` / `Kazi.ReadModel` current vector | none — exists today |
| Q4 | Red→green velocity | `Iteration.regressions` across `list_iterations/1` | none — client-side diff over existing rows |
| Q4 | Budget consumed/cap | `Run.max_iterations` + observed iteration count | none — `budget_tokens` partially rendered already |
| — | Operator/debug mode split | existing routes (DAG/event-river/lease-map unchanged) | Presentational toggle only, scoped in T63.5 |

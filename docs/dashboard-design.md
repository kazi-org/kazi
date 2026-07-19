# Dashboard visual design spec — Mission Control (ADR-0070)

The committed, textual distillation of the approved dashboard design. The
dashboard's home LiveView (`KaziWeb.MissionControlLive`) is styled to THIS spec;
a change of visual direction edits this file first. (The originating design
mockup — a `Mission Control.dc.html` design canvas — lives outside the repo;
this document is self-contained on purpose.)

Mission Control supersedes the earlier **starmap** direction (ADR-0057): the
home view is now an ops-center **card grid**, not a spatial SVG constellation.
The registry / sinks / attention-queue / drill-in infrastructure ADR-0057 built
is unchanged — only the home visual is replaced. The shared design tokens and
motion keyframes live in `KaziWeb.Layouts` (the root layout), so every page —
Mission Control, drill-in, transcript peek, event river — draws from ONE token
set; the token NAMES are stable across the revision (`--rail` now aliases
`--panel`) so the other pages recolor from the new palette untouched.

## Design tokens (CSS custom properties, exact)

```css
:root {
  --bg:     #0A0E14;  /* void background */
  --panel:  #0E1520;  /* card / chip / rail surface */
  --panel2: #101826;  /* inset (harness badge) */
  --rail:   #0E1520;  /* legacy alias of --panel (other pages) */
  --line:   #1B2634;  /* hairlines / borders */
  --txt:    #C9D6E4;  /* primary text */
  --dim:    #5D7189;  /* secondary text / labels */
  --cyn:    #53D6FF;  /* running / active / accent */
  --grn:    #3DFFA0;  /* converged / live / passing */
  --amb:    #FFB454;  /* stale / budget warnings */
  --red:    #FF5566;  /* stuck / errors / failing */
}
```

Bright text (wordmark, card names, alert titles, clock) uses `#EAF3FC`.

Typography: body 12px "JetBrains Mono" (mono everywhere); the wordmark is
"Space Grotesk" 700 (18px, letter-spacing .22em). Section labels: 9–10px,
letter-spacing .26–.30em, `--dim`, uppercase (`.section-label` in the layout).

## Layout shell

A single centered column (NOT a rail + canvas). `.shell` is a full-height flex
column with a soft cyan radial glow at the top; `.inner` is `max-width: 1440px`,
centered, `padding: 0 28px`. Three stacked regions plus a pinned footer:

- **Topbar** (`.topbar`, bottom hairline): wordmark `KAZI` (bright) + `FLEET`
  (cyan, weight 500) on the left; a `LIVE` badge (pulsing green `.livedot`) + a
  `HH:MM:SS UTC` clock on the right. The clock reflects the server time as of the
  last poll tick (a glance, not a wall clock — no per-second client JS, keeping
  the page build-free and tests hermetic). The fleet-count / state filters no
  longer live here — direction B (T63.6) folds them into the FLEET header (below).
  The topbar also carries the **operator/debug mode toggle** (`#mc-mode`, a
  `.segmented .modetoggle` of `OPERATOR` / `DEBUG`; `data-mode` reflects the
  active mode) — see "Operator/debug mode split" below.

## Operator/debug mode split (ADR-0078, T63.7)

Mission Control renders in one of two modes, keyed off the URL query param
`?debug=1` (canonical; its absence is the default **operator** view). The
default is deliberately calm — topbar, NEEDS ATTENTION, FLEET, PLANNED — with
the three EXPERT surfaces absent from the DOM. **Debug** mode additionally
renders:

- a **debug nav** (`#mc-debug-nav`) linking the three full expert pages —
  `#mc-debug-dag` → `/dag`, `#mc-debug-leases` → `/leases` (lease map),
  `#mc-debug-events` → `/events`;
- the inline **SESSIONS** rail (`#mc-sessions`, lease presence);
- the **EVENT RIVER** footer (`#mc-event-river`).

The toggle is a `<.link patch>` pair, so switching modes patches the URL param
without remounting. The choice persists **per browser** via `localStorage`
(`kazi:mc-debug`), mirrored from the URL by the `McDebug` LiveView JS hook
(wired into the LiveSocket in the root layout): the hook writes the store on
every mode change and, on a bare `/` visit, restores a stored debug preference
by asking the server to patch the param back in. The URL stays canonical (so
the first server render is already correct and a shared link carries its mode);
`localStorage` only makes a bare visit sticky.

- **NEEDS ATTENTION** (`#mc-attention`, the "where can I help / what is
  blocking" fan-in — T63.8, IA Q2/Q3; always rendered). It composes TWO
  labeled sub-sections whose entries each NAME the blocker, never just count a
  state:
  - **run attention** (`#mc-attention-runs`, `.attnrow`): the ranked
    `Kazi.Attention.Queue` (one entry per goal+signal). Each alert (`.alert`, a
    link to that goal's drill-in) carries a severity badge (`.asev`: `NEEDS
    YOU` / `STUCK` / `BUDGET` / `FLAKE` / `REGRESS`), the goal name, a named
    detail — the failing predicate id for `:stuck`, `"N of M iteration budget
    consumed (cap M)"` for `:budget` — and a `PEEK →` affordance. Variants:
    `.al-bad` (red) for a needs-a-human cause or a stuck predicate, `.al-warn`
    (amber) for budget / flake / regression.
  - **WAITING ON YOU** (`#mc-attention-waiting`): sessions blocked on a human,
    fanned in fleet-wide from the bus board's `waiting-on-operator` facts
    (E60/T60.3 ships the plumbing; the dashboard only reads it via
    `Kazi.Bus.board`'s `"attention"` list). Each `#mc-waiting-<session>` entry
    names the awaited action (the harness's stdin summary, or "awaiting
    operator input" in the degraded form). A session vs a run is a different
    identity with a different lifecycle (cleared by a human reply, not a state
    change — #1386), so it composes as its own sub-section, not interleaved.
  When both halves are empty, an honest empty state renders
  (`#mc-attention-empty`, "Nothing needs you right now."). Reading the board is
  best-effort (ADR-0011 §2): an unreachable daemon degrades to an empty
  WAITING sub-section, never a crash.

- **FLEET** (`#mc-fleet`): a `.fleethead` row — a `FLEET · N LIVE|CLOSED` label
  on the left and, folded into the header on the right (direction B, T63.6), a
  `.fleetcontrols` cluster of **segmented controls**: the **state filter**
  (`#mc-fleet-chips`, a `.segmented` group of `.seg` buttons — `RUNNING` cyan dot,
  `CONVERGED` green dot, `STUCK` red dot, `OVER-BUDGET` amber dot; each a toggle
  that filters the grid to that state, `.seg.on` highlights the active one,
  clicking again clears it; counts sum to the shown cards, `OVER-BUDGET` split
  out of `STUCK`, computed after the repo/time filters but before the state
  filter), the **CURRENT/CLOSED scope toggle** (`#mc-scope`, a `.segmented
  .scopetoggle` of `CURRENT · n` / `CLOSED · m`), and the **repo/time filter
  form** (`#mc-filters`: a repo dropdown, project = `org/repo`, default
  `ALL REPOS`, and a time-window dropdown `ALL TIME` / `LAST 1h · 6h · 24h · 7d ·
  30d`, filtering by last-active; a `#mc-filters-busy` spinner shows while a
  change is in flight). Below the header the flat grid **groups by project**
  under ruled headers (`.projgroup` / `.projgroup-head`, `data-project-group`):
  one `.grid` per `org/repo`, newest run's project first. A single-project fleet
  drops the redundant header and renders one bare grid. Cards are one per goal
  (its latest run), newest first. CURRENT (default) shows live-session runs;
  CLOSED shows dead history (converged / stuck / crashed-stale). An empty CURRENT
  grid with closed history points at the CLOSED toggle rather than implying
  nothing ran (`#mission-control-empty`). Overflow past the card cap folds into a
  `+N more on the goal board →` link (`#mc-older`, → `/goals`). The state filter
  and NEEDS ATTENTION alerts honor the same scope; roadmap wave mode ignores it
  (durable-plan state across all runs). Filters that hide every run render
  `#mission-control-filtered-empty` (an honest "clear the filters" message)
  rather than the no-runs empty state.

- **PROGRESS RATE** (`#mc-progress`, operator view; rendered only when at least
  one active goal has recorded iterations): the honest answer to the operator's
  "how long until done" question (IA Q4, T63.9). It is **rate-only per ADR-0046**
  — no ETA, no date, no duration is ever computed or displayed. A `.section-label`
  (`PROGRESS RATE · OBJECTIVE RATES ONLY`) + an affordance line stating that kazi
  does not guess a finish, above a `.grid` of one `.card.prog` per active goal
  (`#mc-progress-<goal_ref>`, `data-goal-ref`). Each card shows three `.progrow`
  metrics (`data-metric`): **PREDICATES GREEN** (the `passing / total` ratio over
  the latest vector), **FLIP VELOCITY** (`per_iteration /iter · N red→green`, the
  red→green flips summed over recent iteration transitions; a single-iteration
  goal shows an honest `— needs 2+ iterations`, never a fabricated `0`), and
  **BUDGET CONSUMED** (`consumed / cap iterations`, or `consumed iterations · no
  cap` for an unbounded goal). Backed by the `Kazi.ReadModel.goal_progress_rate/1`
  projection (`Kazi.ReadModel.GoalProgressRate`; ADR-0011 projection only — the
  predicate/flip data from the iterations log, the budget from the run registry).
  Every label is a rate or ratio by construction; the panel's own copy names no
  date/ETA so the operator learns the number is objective, not a promise.

- **EVENT RIVER** (`#mc-event-river` `.river` footer, top hairline; **debug mode
  only** — ADR-0078): a `.section-label` + a masked marquee ticker (`.ticker`,
  48s linear scroll, span duplicated for a seamless loop) of `[HH:MM:SS] goal ·
  event` entries — the newest fleet-wide events (`Kazi.Sink.Events`, the same
  source `/events` reads). Empty → `#mission-control-river-empty`.

## Fleet cards

Each run-backed card (`.card`, a link to `/goals/:ref/drillin`) stacks:

- **Top** (`.cardtop`): the goal name (`.gname`, bright bold) + a state pill
  (`.stpill`): `RUNNING` (`.st-run` cyan) / `CONVERGED` (`.st-ok` green) /
  `STUCK` (`.st-bad` red) / `STALE` (`.st-warn` amber) / `OVER-BUDGET`
  (`.st-bad`, its own label). Card frame mirrors state: `.c-run` quiet cyan,
  `.c-ok` green glow, `.c-bad` red alarm glow (pulses), `.c-warn` amber.
- **Meta** (`.gmeta2`): a harness badge (`.hbadge`, `harness · model`), the
  workspace basename (`.ws`), `ITER n`, and a single right-aligned relative
  timestamp (`.cardtime`, `5m ago` — the last heartbeat, falling back to the run
  start). Direction B (T63.6) removed the per-card project badge — the `org/repo`
  provenance now lives in the grid's ruled project-group header — and collapsed
  the two-value AGE/ACTIVE row into this one timestamp.
- **Predicate DNA** (`.dnarow`): one 14px square per predicate in the LATEST
  iteration's vector — `.dna.dg` green (pass), `.dna.dr` red (fail/error),
  `.dna.dx` dark (not-evaluated). A large set folds a trailing `+N`.
- **Bottom** (`.cardbot`): a **burn bar** (`.burn` / `.burnfill`, colored by
  fraction: `.b-ok` cyan < 65%, `.b-warn` amber 65–85%, `.b-hot` red ≥ 85%)
  with its label, plus a 72×20 green **sparkline** SVG of passing-predicate
  count over the iteration history.

The card's DNA / sparkline / burn / iter come from the SAME persisted
per-iteration history the drill-in heatmap reads (`Kazi.ReadModel`); nothing is
fabricated. A run with no recorded iterations shows an empty DNA strip and
`ITER —`.

### The burn bar — an honest deviation from the mock

The originating mock's burn bar reads `412k / 600k tokens`. kazi's run registry
has no token *cap* — the only budget it authoritatively knows is
`max_iterations` (per ADR-0046 the harness reports tokens USED, not a ceiling).
So the bar reads **iteration** progress (`iter n / max`, same `b-ok/b-warn/b-hot`
thresholds), and harness-reported tokens (`Run.budget_tokens`) ride alongside as
text (`· 412k tok`) only when present. Nothing is fabricated: no cap is invented
to fake a token fraction.

### Remote cards — cross-machine visibility (T60.1, #1154)

A goal running on a DIFFERENT machine is invisible to `RunRegistry.list/0`
(the per-machine SQLite read-model, ADR-0057) but may still be visible on the
session bus, via `Kazi.Runtime.BusMirror`'s `run:<short-id>` facts. The fleet
grid folds these in as **remote cards**: a lighter card (no project badge,
harness, DNA strip, burn bar, or sparkline — none of that is knowable from a
free-text bus fact) showing only the goal name, a state pill derived from the
fact's verb (`started`/`iter` → running, `converged` → converged, anything
else terminal → stuck), and a `.csub` line reading `remote · <machine>`.
`data-remote="true"` distinguishes it from a local placeholder card in the
markup. A goal_ref already present in the LOCAL registry is never duplicated
as a remote card. Best-effort (ADR-0011 §2 / ADR-0067 point 1's mirror
invariant): an unreachable daemon or a fact the parser can't recognize simply
yields zero remote cards — the local fleet grid is unaffected either way.

## Roadmap wave grouping (preserving T47.2)

When `kazi dashboard --roadmap <goal-file>` configures a roadmap goal
(`KaziWeb.Starmap.GoalSource` returns a `Kazi.Goal.t()`), the FLEET grid GROUPS
into labeled **wave sections** — one per topological frontier from
`Kazi.Goal.DepGraph.frontiers/1`, the SAME computation `kazi apply --explain`
prints (one function, two renderers, so the dashboard and the schedule can never
disagree). The header reads `ROADMAP · N GOALS · M WAVES`; each wave is a
`WAVE k · <ACTIVE|LANDED|FRONTIER|HORIZON>` sub-header (`.wavehead`) over its own
card grid.

A declared group with a registered run shows its live card; a group nothing has
dispatched yet shows a lighter **placeholder** card (a plain tile, not a link,
`data-run="false"`):

- `CLAIMED` (`.c-claimed` dashed cyan frame) — every `needs` dep converged, the
  live frontier, eligible to dispatch now.
- `PENDING` (`.c-pending` dim) — still waiting on an unconverged dep, or poisoned
  behind a stuck ancestor (`DagSnapshot`'s `:blocked`, folded in).

Roadmap-mode wave state resolves from the LATEST run per group across the whole
registry (the roadmap is the durable plan — a group converged by a since-closed
session still reads landed); flat mode scopes to CURRENT sessions. With no
roadmap configured (the default) the fleet is a single flat grid — the fallback,
not a separate mode.

## Motion (reduced-motion gated)

All animation sits under `@media (prefers-reduced-motion: no-preference)`;
keyframes are defined once in `KaziWeb.Layouts`:

- `mc-pulse` (1.6s) — the `LIVE` dot.
- `mc-alarm` (2.2s) — the red glow on `.c-bad` (stuck) cards.
- `mc-scroll` (48s) — the event-river ticker.

No motion otherwise — static styles must read correctly with animations off.

## Mobile (≤ 820px)

No separate tab bar — a card grid is inherently responsive. Below 1080px the
alert + fleet grids drop to 2 columns; below 820px to a single column, the
topbar wraps, and the clock/LIVE badge move into the thumb zone. The event river
stays pinned at the bottom. Desktop above the breakpoint is untouched.

## Mapping to existing views

- `MissionControlLive`: the topbar + attention + fleet grid + river (river
  content from the T47.1 events sink). Retains ADR-0057's read-only projection
  contract (ADR-0011 §2): it renders state, never mutates a run/goal/lease. Its
  only interactions are navigation links into the full-page views.
- `DrillinHeatmapLive`: the full per-goal analyst view — convergence heatmap +
  iteration scrubber + transcript peek. Every fleet card and alert deep-links
  here (`/goals/:ref/drillin`); this is Mission Control's "drill in".
- `TranscriptPeekLive` / `EventRiverLive` / `GoalBoardLive` / `LeaseMapLive` /
  `DagLive`: the other full-page views, recolored from the shared token set.
- States map: converged→landed, running→converging (or stale on a dead
  heartbeat), stuck/over_budget/error→stuck; roadmap placeholders add
  claimed/pending from the `DagSnapshot` frontier.

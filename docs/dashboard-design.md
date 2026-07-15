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
  (cyan, weight 500) on the left; the **fleet-count chips** centered
  (`RUNNING` cyan dot, `CONVERGED` green dot, `STUCK` red dot, `OVER-BUDGET`
  amber dot — each a `.chip` with a glowing `.dot`); a `LIVE` badge (pulsing
  green `.livedot`) + a `HH:MM:SS UTC` clock on the right. The counts sum to the
  shown fleet cards (`OVER-BUDGET` is split out of `STUCK`, never double-counted).
  The clock reflects the server time as of the last poll tick (a glance, not a
  wall clock — no per-second client JS, keeping the page build-free and tests
  hermetic).

- **NEEDS ATTENTION** (`#mc-attention`, rendered only when the queue is
  non-empty): a `.section-label` + a 3-column grid (`.attnrow`) of **alert
  cards**. Each alert (`.alert`, a link to that goal's drill-in) carries a
  severity badge (`.asev`: `NEEDS YOU` / `STUCK` / `BUDGET` / `FLAKE` /
  `REGRESS`), the goal name (`.atitle`), a truncated one-line detail
  (`.adetail`), and a `PEEK →` affordance. Variants: `.al-bad` (red border +
  glow) for a needs-a-human cause or a stuck predicate; `.al-warn` (amber) for
  budget / flake / regression. Ranked and de-duplicated by
  `Kazi.Attention.Queue` (one entry per goal+signal).

- **FLEET** (`#mc-fleet`): a `.fleethead` row — a `FLEET · N LIVE|CLOSED` label
  plus a **CURRENT/CLOSED scope toggle** (`#mc-scope`, `.scopebtn` pills showing
  `CURRENT · n` / `CLOSED · m`) — then a 3-column `.grid` of **goal cards**, one
  per goal (its latest run), newest first. CURRENT (default) shows live-session
  runs; CLOSED shows dead history (converged / stuck / crashed-stale). An empty
  CURRENT grid with closed history points at the CLOSED toggle rather than
  implying nothing ran (`#mission-control-empty`). Overflow past the card cap
  folds into a `+N more on the goal board →` link (`#mc-older`, → `/goals`). The
  chips and NEEDS ATTENTION alerts honor the same scope; roadmap wave mode
  ignores it (durable-plan state across all runs).

- **EVENT RIVER** (`.river` footer, top hairline): a `.section-label` + a
  masked marquee ticker (`.ticker`, 48s linear scroll, span duplicated for a
  seamless loop) of `[HH:MM:SS] goal · event` entries — the newest fleet-wide
  events (`Kazi.Sink.Events`, the same source `/events` reads). Empty →
  `#mission-control-river-empty`.

## Fleet cards

Each run-backed card (`.card`, a link to `/goals/:ref/drillin`) stacks:

- **Top** (`.cardtop`): the goal name (`.gname`, bright bold) + a state pill
  (`.stpill`): `RUNNING` (`.st-run` cyan) / `CONVERGED` (`.st-ok` green) /
  `STUCK` (`.st-bad` red) / `STALE` (`.st-warn` amber) / `OVER-BUDGET`
  (`.st-bad`, its own label). Card frame mirrors state: `.c-run` quiet cyan,
  `.c-ok` green glow, `.c-bad` red alarm glow (pulses), `.c-warn` amber.
- **Meta** (`.gmeta2`): a harness badge (`.hbadge`, `harness · model`), the
  workspace basename (`.ws`), and `ITER n`.
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

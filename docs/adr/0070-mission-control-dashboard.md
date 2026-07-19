# ADR 0070: Mission Control — the fleet home view as an ops-center card grid

## Status
Accepted

## Date
2026-07-14

## Refines / supersedes
Supersedes the **home-view** decision of ADR-0057 (the "starmap" constellation)
— point 4's "Home view: the starmap" only. Everything else ADR-0057 decided
stands unchanged and is reaffirmed: the read-only projection contract (ADR-0011
§2), the run registry with heartbeats, the per-run append-only JSONL sinks, the
`kazi dashboard` standalone mode, and the per-goal drill-in (convergence heatmap
+ transcript peek). This ADR replaces only how the FLEET is visualized on the
landing page.

Also depends on: ADR-0056 (the roadmap goal-DAG — its wave grouping is preserved
here, T47.2), ADR-0046 (per-iteration counters — the burn/DNA data), ADR-0055
(the implicit `landed` predicate — a card state), ADR-0034 (docs land with the
code — `docs/dashboard-design.md` is rewritten in this same change).

## Context

ADR-0057 built the fleet-observability substrate (registry + sinks + attention
queue + drill-in) and chose a **starmap** — a spatial SVG constellation of the
goal DAG in wave bands — as the home view. In dogfooding, the constellation
proved to be the weak half of that decision:

1. **Spatial layout fought the data.** A flat fleet (the common case, with no
   roadmap configured) has no inherent geometry, so the constellation invented
   band columns and organic offsets that carried no real information — density
   past ~48 nodes forced a canvas cap and vertical scroll, and the per-node SVG
   text labels were the readability floor, not the ceiling.
2. **Per-goal convergence was a click away.** The predicate DNA, burn, and
   convergence detail lived only in the slide-over panel; the glance view showed
   a colored dot per run. "Which goals are burning budget / regressing right
   now" needed N clicks.
3. **The interaction surface was heavy** for a read-only glance: session
   filters, state-tile filters, a session-scope toggle, a slide-over panel, and
   a bespoke mobile tab bar — all bespoke to the constellation.

A card grid answers the same questions with less: each goal is a card that
shows its state, predicate DNA, iteration burn, and a convergence sparkline
inline; attention is a dedicated top row; the whole thing reflows responsively
with no bespoke mobile mode. The design was rendered as a `Mission Control`
design canvas and chosen as the replacement.

## Decision

1. **The fleet home view is an ops-center card grid** (`KaziWeb.MissionControlLive`
   at `/`, `/starmap` retained as an alias). Layout: a topbar fleet-count strip,
   a **NEEDS ATTENTION** row (the ranked `Kazi.Attention.Queue`), a **FLEET**
   grid of one card per goal, and a pinned **EVENT RIVER** ticker. The normative
   visual spec is `docs/dashboard-design.md`.

2. **Per-card convergence at a glance.** Each run-backed card renders, inline,
   the goal's latest predicate vector as a DNA strip, a passing-predicate
   sparkline over the iteration history, and an iteration **burn bar** — all
   from the SAME persisted per-iteration history the drill-in heatmap reads
   (`Kazi.ReadModel`). Nothing is fabricated; a run with no iterations shows an
   empty strip and `ITER —`.

3. **Honest budget.** kazi's registry has no token *cap* (per ADR-0046 the
   harness reports tokens USED, not a ceiling), so the burn bar reads the only
   budget the registry authoritatively knows — iteration progress against
   `max_iterations` — with harness-reported tokens shown as text alongside when
   present. The mock's "k / k tokens" fraction is deliberately NOT reproduced,
   because there is no cap to make it honest.

4. **The roadmap DAG is preserved as wave grouping, not dropped.** When
   `kazi dashboard --roadmap <goal-file>` configures a roadmap
   (`KaziWeb.Starmap.GoalSource`), the fleet grid GROUPS into labeled wave
   sections — one per topological frontier from `Kazi.Goal.DepGraph.frontiers/1`,
   the SAME computation `kazi apply --explain` prints (one function, two
   renderers). Declared-but-undispatched groups render as `CLAIMED` (eligible
   frontier) / `PENDING` (waiting on deps) placeholder cards. So the roadmap's
   structural value (topological order, what's blocking what, what's next to
   dispatch) survives natively in the card idiom, and the `--roadmap` flag keeps
   a real meaning. With no roadmap, the fleet is a single flat grid — the
   fallback, not a separate mode.

5. **Read-only, low-interaction.** Mission Control renders state and never
   mutates a run/goal/lease (ADR-0011 §2 reaffirmed). Its interactions are the
   2-second poll-tick refresh, navigation deep-links into the full-page views
   (drill-in, goal board, event river), and a **CURRENT/CLOSED scope toggle**
   that scopes the grid, chips, and attention alerts — carried over from the
   starmap so crashed/closed history stays reviewable on the home screen (it is
   the one starmap control worth keeping; the per-node filters and slide-over are
   retired). The mobile tab bar is dropped for plain CSS grid reflow.

## Alternatives considered

- **Keep the starmap, add inline card telemetry to its nodes.** Rejected: SVG
  text is the readability floor; cramming DNA/burn/sparkline into a `<circle>`
  label reintroduces the density problem the cap exists to bound.
- **Drop the roadmap wave feature entirely.** Considered when the starmap's
  wave bands were retired — the `--roadmap` flag and `GoalSource` are consumed
  only by the home view. Rejected in favor of decision 4: the topological
  frontier information is genuinely useful and maps cleanly onto grouped card
  sections, so removing it would lose value the flat grid can't express.
- **Leave `--roadmap` as a dormant no-op flag.** Rejected: a flag that silently
  does nothing is a wart and violates "docs land with the code" (ADR-0034) — the
  honest options are "remove it" or "give it a real meaning"; decision 4 does the
  latter.

## Consequences

- The fleet-glance questions ("what's stuck, what's over budget, what's
  regressing, what's next to dispatch") are answered without a click; the
  drill-in page is reached by a deep-link, not a slide-over.
- ADR-0057's substrate is untouched — this is a pure home-view swap, so the
  registry/sinks/attention/drill-in and their tests carry over. The starmap
  LiveView and its constellation-specific tests are removed; the `--roadmap`
  CLI-seam coverage and the attention-queue ranking coverage move to the new
  view's tests / are retained at the core (`Kazi.Attention.Queue`).
- The shared design tokens change values (a brighter, higher-contrast palette)
  but keep their NAMES (`--rail` now aliases `--panel`), so every other
  full-page view recolors from the new palette with no per-view edit.
- `KaziWeb.Starmap.GoalSource` keeps its module name (and its `:starmap_*`
  application-env keys) despite the starmap's retirement — renaming the
  namespace is a mechanical follow-up, deliberately deferred to keep this change
  a focused home-view swap.

## Epic
E46 (`docs/plans/E46.md`), UC-061.

# ADR-0078: Mission Control defaults to an OPERATOR view; expert surfaces sit behind a DEBUG toggle

## Status

Accepted

## Date

2026-07-18

## Context

Mission Control (`lib/kazi_web/live/mission_control_live.ex`, ADR-0070, UC-061)
is the fleet home view. It grew three EXPERT surfaces that a daily operator
rarely reads but a debugging author needs: the **event river** (the fleet-wide
event ticker, `KaziWeb.EventRiverLive`), the **lease map** (cross-machine
lease/coordination presence, `KaziWeb.LeaseMapLive` and the inline SESSIONS
rail), and the **DAG** view (`KaziWeb.DagLive`). Operator feedback on E63
(David, 2026-07-17) named the page "intimidating": too many expert widgets
compete with the four questions an operator actually asks (what is the fleet
working on; where can I help; what is blocking; how much longer -- see T63.4's
IA proposal, `docs/design-mocks/t63.4/proposal.md`).

The T63.4 proposal, APPROVED AS-IS (E63 Notes, 2026-07-18), prescribes a
default **operator** mode that shows only the fleet grid, the attention queue,
and the rate displays, with a single toggle -- "a single link/switch, not a
separate route" -- into a **debug** mode that reveals the existing expert
surfaces unchanged. This is a presentational filter over EXISTING
routes/components; it introduces NO new read-model query and does not touch the
ADR-0011 read-only projection. Two audiences, one read-model.

The open decision this ADR settles: **how the mode is represented and
persisted per browser** -- a URL query parameter, browser `localStorage`, or
both.

## Decision

### 1. Two modes, one page, no new route

Mission Control renders in one of two modes:

- **operator** (default) -- the topbar, NEEDS ATTENTION, the FLEET grid, and
  PLANNED. The expert surfaces are absent from the DOM (not merely hidden with
  CSS): no event-river footer, no SESSIONS rail, no DAG/lease-map links.
- **debug** -- everything operator shows, PLUS the expert surfaces: the SESSIONS
  rail (lease presence), the EVENT RIVER footer, and a debug nav strip linking
  the three full expert pages (`/dag`, `/leases`, `/events`).

The expert full-page routes (`/dag`, `/leases`, `/events`) are unchanged and
remain directly reachable by URL -- the split governs only what Mission Control
itself surfaces by default. Nothing about the data model changes; the same
projections feed both modes.

### 2. The mode is a URL query parameter (`?debug=1`), canonical

The mode lives in the URL: `?debug=1` selects debug; its absence selects
operator. `handle_params/3` reads it into a single `:debug?` assign; the toggle
is a `<.link patch>` that adds or drops the param (a patch, so the LiveView
stays mounted -- no full remount, ADR-0070's glance-not-reload property holds).

**Why the URL, not `localStorage` as the source of truth:** Mission Control is
server-rendered LiveView. The DOM the very first render emits must already be
correct for the mode -- the ExUnit render test asserts that a default mount
carries NO expert markup and a debug mount carries all of it, with no
round-trip. `localStorage` is unreadable at server render time, so making it
canonical would force a flash-of-operator-then-swap and an untestable initial
DOM. A query param is readable at mount, keeps the initial DOM authoritative,
and is a bonus shareable/bookmarkable ("open my dashboard in debug").

### 3. `localStorage` MIRRORS the param for per-browser persistence

A URL param alone is not "per browser" -- a fresh visit to `/` would forget the
choice. So a small LiveView JS hook (`McDebug`, wired into the LiveSocket in the
root layout) gives the persistence the task requires:

- on the server, each `handle_params` **pushes the active mode to the client**
  (`push_event("mc-store-debug", %{on: debug?})`); the hook writes
  `localStorage["kazi:mc-debug"]` so the store always mirrors the live mode;
- on connect, the hook reads `localStorage`; if it holds `"1"` and the URL has
  NO `debug` param (a bare `/` visit), it asks the server to restore debug
  (`pushEvent("mc-restore-debug")` -> `push_patch` to `?debug=1`).

Net: the URL is canonical and testable; `localStorage` makes the choice sticky
per browser across bare visits. An explicit shared link (`/` or `/?debug=1`)
still wins for that navigation, because the hook only restores when the URL is
silent on the mode.

## Consequences

- The default dashboard is calmer: three expert surfaces leave the operator
  view, addressing the "intimidating" feedback without deleting any capability.
- The expert surfaces and their full pages are one `?debug=1` (or one toggle
  click) away, and the choice sticks per browser.
- No read-model or projection change; ADR-0011 §2 (read-only projection) and
  ADR-0070 (Mission Control) are unaffected -- this is presentation only.
- The event river and SESSIONS rail render only in debug, so their existing
  ExUnit coverage moves to a `?debug=1` mount (behavior unchanged, location of
  the assertion changes).
- A browser without JS still works: it defaults to operator and can enter debug
  by URL; only the `localStorage` stickiness needs the hook.

## Alternatives considered

- **`localStorage` as the canonical source** -- rejected: unreadable at server
  render, forcing an untestable initial DOM and a visible flash.
- **A separate `/debug` route** -- rejected: the T63.4 proposal explicitly wants
  "a single link/switch, not a separate route", and a route would duplicate the
  whole Mission Control mount for a presentational filter.
- **A server-session (cookie) flag** -- rejected: heavier than a param+hook, not
  shareable, and still needs a write path; the query param already gives a
  testable, linkable canonical state.

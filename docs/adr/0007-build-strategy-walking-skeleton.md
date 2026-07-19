# ADR 0007: Build strategy -- walking skeleton + self-hosting (vertical, not horizontal)

## Status
Accepted

## Date
2026-06-21

## Context

kazi must eventually cover much of the software lifecycle (convergence, creation,
maintenance). The naive way to build it is horizontally -- finish one lifecycle
phase (ideate, then specify, then plan, ...) across the whole tool before the
next. That order cannot be dogfooded: a phase built in isolation (e.g. an
idea-to-predicate front-end) has nothing behind it to converge against, so its
correctness can only be eyeballed -- the same subjective check that makes the
prior prose-skill pipeline "kind of work but not well." It also front-loads the
least-validatable part and defers the core value.

## Decision

Build kazi as a **walking skeleton**: the thinnest possible path end-to-end
through all phases for a trivial goal, then deepen slice by slice. Slicing is
**vertical** (a whole thin path per slice), never **horizontal** (a whole phase
at a time). Start from the **convergence core**, the piece that is both the
primary pain and objectively testable -- not the front-end.

The walking skeleton spans **idea -> production from Slice 0**: every lifecycle
phase gets its thinnest version on day one, and later slices DEEPEN phases rather
than add missing ones.

- **Slice 0** -- walking skeleton, idea -> production: one goal spanning code +
  live predicates (tests green AND a live prod probe), test-runner + http_probe
  providers, a `claude -p` adapter, and the convergence state machine with
  non-agent **actions** (integrate: branch/PR/merge; deploy: ship the artifact to
  a tiny deployable fixture), evidence persisted. Success criterion: kazi cannot
  declare success while any predicate -- code OR live -- fails.
- **Slice 1** -- regression + flake + budget/stuck handling; prod-log predicate.
- **Slice 2** -- creation mode (failing acceptance predicates + browser provider
  + vacuous-goal guard); kazi can now build, not only repair.
- **Slice 3+** -- DEEPEN: JetStream leases, graph partitioning, richer deploy
  (multi-env/rollback), standing reconcilers, idea->predicate front-end,
  dashboard, notifications -- each added only when a slice needs it, not because
  the lifecycle diagram lists it.

**Bootstrap then self-host.** Slices 0-2 are built with the existing Claude Code
skills (brainstorm/plan/apply/verify) because kazi cannot yet build itself. From
Slice 2 onward, kazi builds kazi: each new capability is a kazi goal expressed as
failing acceptance predicates. The dogfood becomes self-hosting, and the hardest
test case (kazi building kazi) validates the thesis.

The overall success bar for the iteration: **kazi converges a goal that a prose
brainstorm->plan->apply->verify->qualify pipeline left subtly broken.**

## Consequences

- Every slice is end-to-end and therefore dogfood-able from Slice 0; no
  capability is validated only by inspection.
- Lifecycle completeness emerges as a consequence of deepening slices, which
  curbs the overbuild reflex (a phase is built only when a slice demands it).
- Slice 0 reaching production means the thinnest integrate + deploy + verify-live
  exist from day one, including one human task (cloud target provisioning) and a
  tiny deployable fixture. The deploy action sits behind a stub so the rest of
  Slice 0 proceeds without the cloud target.
- Slice 0 defines the provider/adapter/action behaviours first, so providers, the
  adapter, the actions, and the loop build in parallel against contracts; the
  only hard serialization is the state-machine spine and final wiring.
- Product prioritization (what to build) stays human and out of scope; kazi
  executes declared goals.
- If Slice 0 fails the success bar, the cost is days, not a quarter.

# ADR 0082: Generated roadmap view lands beside the WBS, not in place of it

## Status
Proposed (operator acceptance required; supersedes the scope of ADR-0056
decision 3 for the plan.md cutover)

## Date
2026-07-19

## Context
T45.9 (migrate kazi's own WBS to a roadmap goal-DAG) is blocked on issue
#1554: the shipped `kazi plan render` grammar is goal-level only. A clean
feasibility run (v1.258.0/v1.260.0) showed that replacing `docs/plan.md`
byte-for-byte with render output would (1) collapse `parse_plan.py`'s task
discovery to zero tasks, destroying the `/apply --pool` coordination
substrate; (2) turn every `[x]` goal into a doc-freshness offender because
the checkers walk `TNN ... Done: <date>` task lines; and (3) lose fidelity
the read-model does not hold (acc:/Owner/Est/deps, use cases, risks,
archived-epics index), violating no honest path to the T45.9 acceptance as
written. Issue #1554 laid out three options: (A) extend render to task-level
grammar, (B) land the generated view as a separate file and keep plan.md's
structure, (C) teach the parsers/checkers to read the read-model.

## Decision
Option B. `kazi plan render` output lands as a SEPARATE committed file,
`docs/plan-generated.md`, carrying the generated banner and regenerated on
state change. `docs/plan.md` and `docs/plans/*.md` remain the task-level WBS
and the single coordination substrate for `/apply --pool`, `parse_plan.py`,
and the doc-freshness checkers, unchanged.

Rationale: option A requires the read-model to hold the full WBS fidelity it
was deliberately not given (ADR-0056 decision 3 keeps the read-model at goal
grain), so extending the grammar cannot recover acc:/deps/prose without a
much larger data-model change; option C would make read-only graders depend
on a mutable runtime store and parse_plan.py is shared across repos. Option B
is atomic, reversible, requires no kazi-core change, and still delivers the
dogfood value: the roadmap goal-DAG is authored, linted, persisted, and its
generated view is committed and diffable beside the WBS.

## Consequences
- T45.9 is re-scoped: the cutover criterion changes from "plan.md becomes
  render output" to "docs/plan-generated.md is the committed render of the
  live roadmap, kept fresh, with kazi status reflecting real epic state".
- ADR-0056 decision 3's "read-model is truth" claim is narrowed: the
  read-model is truth for GOAL-level state; task-level truth remains the
  WBS files until a future ADR gives the read-model task fidelity.
- A future option-A ADR may still replace plan.md wholesale once (and only
  once) render can express the full substrate; nothing here forecloses that.
- Issue #1554 closes when this ADR is accepted and the re-scoped T45.9
  lands.

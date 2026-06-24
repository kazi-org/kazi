# ADR 0028: Dependency-aware partitioning (predicate-graph waves)

## Status
Accepted

## Date
2026-06-24

## Builds on
ADR-0020 (hierarchical predicate grouping / the `[[group]]` taxonomy) and ADR-0027
(the native parallel scheduler). This ADR adds the ONE thing those two lack to
fully codify the operator's `/plan` `deps:` + `/apply` Waves: SEMANTIC ORDERING in
the scheduler.

## Context

The operator's `/plan` + `/apply` skills parallelize via WAVES: `/plan` reasons
about a goal, declares task `deps:`, and groups tasks into ordered waves; `/apply`
executes wave-by-wave (parallel within a wave, a barrier between waves, self-verify,
advance). kazi now has three of the four ingredients to replace that:

- **Objective done** -- predicates with evidence (ADR-0002), better than `/apply`'s
  LLM self-verify.
- **Spatial parallelism** -- blast-radius partitioning, disjoint-by-construction
  (ADR-0006), finer and safer than `/claim`'s task-id locks.
- **A native scheduler** -- partitions a goal-set and drives N supervised
  reconcilers to collective convergence (ADR-0027).

The MISSING fourth ingredient is **semantic ordering**. kazi's scheduler partitions
by blast radius (spatial disjointness) and runs disjoint partitions in parallel; it
has NO notion that "group B must converge AFTER group A" when B logically depends on
A's output (e.g. the streaming predicates need the result-contract predicates to be
true first). Two partitions that are spatially disjoint but logically ordered would
both run -- kazi cannot sequence them. ADR-0020's group taxonomy has parent/child
edges, but those are for BUDGET ROLLUP + reporting, not execution order. So today
the semantic precedence the operator authors as `deps:`/Waves has no home in kazi,
and that intelligence stays in the personal `/plan` skill.

This ADR closes that gap so kazi can COMPUTE the wave schedule itself from authored
dependency edges, rather than the operator hand-authoring waves.

## Decision

Add a **dependency DAG over predicate groups** and make the scheduler execute it
topologically, with blast-radius parallelism inside each frontier and objective
convergence as the gate. Concretely:

1. **Declare dependency edges in the taxonomy.** Extend the `[[group]]` entry
   (ADR-0020) with an optional `needs = ["group-id", ...]` -- a "must-converge-
   before" edge set, DISTINCT from `parent` (which remains budget-rollup only).
   Validated at load like every other taxonomy reference (ADR-0020's drift guard):
   every `needs` id must exist, no self-edge, no cycle (considering `needs` edges;
   `parent` and `needs` are independent relations). `needs` is OPTIONAL -- absent
   edges mean fully parallel (today's ADR-0027 behavior).

2. **Compute the ready set (pure).** From the `needs` edges + each group's current
   convergence state, derive the READY SET = groups whose every `needs` dependency
   has OBJECTIVELY converged (its predicates true, evidence-backed -- not "an agent
   said done"). Pure, deterministic, no I/O.

3. **Topological + spatial execution, pipelined (no global barrier).** The
   scheduler (ADR-0027) dispatches only ELIGIBLE groups -- those in the ready set --
   partitioning that ready set by blast radius and running the partitions
   concurrently. As each group converges, the ready set is RE-EVALUATED and
   newly-eligible groups dispatch immediately. A group becomes ready the moment ITS
   specific deps converge -- NOT when a whole "wave" finishes. This is strictly
   better than `/apply`'s static wave barrier (no slowest-in-wave tax).

4. **Objective, adaptive re-gating.** Because readiness is defined by objective
   convergence, a dep that later REGRESSES (the regression guard fires) re-gates its
   dependents: they return to not-ready and re-converge. The DAG is re-evaluated
   against OBSERVED state each cycle -- the reconciler property, not a one-shot plan.

5. **Blocked-dependency escalation.** If a dep group goes `stuck` / `over_budget`,
   its dependents can never become ready; the scheduler escalates the affected
   sub-DAG and NAMES the blocking dep in the collective report (ADR-0027 `--json`),
   rather than hanging silently (the `/apply` wave-stall failure mode, made
   observable).

This composes ADR-0020 (taxonomy) + ADR-0027 (scheduler): the dependency layer
decides WHICH partitions are eligible; the spatial scheduler runs them. No new loop;
no new subsystem.

## Consequences

- kazi can COMPUTE a conflict-free, pipelined, objectively-gated wave schedule from
  declared dependency edges -- the full codification of `/plan`'s `deps:` + `/apply`'s
  Waves. The operator authors edges ONCE (as predicate-group `needs`); kazi derives
  and re-derives execution.
- This is strictly more than `/apply` waves: spatial parallelism inside frontiers is
  conflict-free-by-construction, the gate is objective, there is no slowest-in-wave
  barrier, and the schedule adapts to regressions.
- The IRREDUCIBLE input is the dependency edges: kazi cannot DERIVE logical
  precedence from code (only spatial disjointness). The operator (or a future
  `propose`/importer) still authors `needs`. This is honest -- semantic order is
  human/LLM judgment; kazi computes everything downstream of it.
- Over-declaring `needs` re-serializes (loses parallelism); deps are optional and the
  scheduler can print the computed order so over-constraint is visible.
- Cycles are unsatisfiable and rejected at load (like ADR-0020's parent-cycle guard).

## Alternatives rejected

- **Reuse `parent` for ordering.** Conflates budget rollup (ADR-0020) with execution
  order; a group's budget parent is not necessarily its execution predecessor.
  Separate `needs` edges keep the two relations independent.
- **Infer order from blast radius alone.** Spatial disjointness != logical
  independence; two disjoint groups can still be ordered (B consumes A's new API).
  Blast radius cannot express precedence -- hence explicit `needs`.
- **Static waves like `/apply` (barrier between frontiers).** Wastes the
  slowest-in-frontier wall-clock; kazi pipelines per-group readiness instead.
- **Derive `deps` with an LLM at run time.** Non-deterministic ordering in the core
  loop; authoring `needs` is a one-time declaration validated at load, consistent
  with ADR-0002's machine-checkable, deterministic ethos.

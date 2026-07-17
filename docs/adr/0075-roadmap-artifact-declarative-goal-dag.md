# ADR 0075: The roadmap artifact -- a declarative goal-to-goal DAG, distinct from a fleet

## Status

Accepted

## Date

2026-07-17

## Refines

ADR-0065 (safe concurrent work: `kazi apply --fleet` over goal-files). Responds
to T45.1 / UC-059 (the roadmap artifact: loader + schema for a goal DAG).

## Context

kazi already has a goal-to-goal DAG concept: a **fleet** (ADR-0065). `kazi apply
--fleet <dir|manifest>` loads several goal-files, computes the edges between
them, and EXECUTES that DAG through the partition scheduler. A fleet's edges are
DECENTRALIZED -- each goal-file declares its own predecessors in its
`[metadata] depends_on` key, plus inferred scope-overlap serialization -- and its
members are PATHS only (a directory of `*.goal.toml`, or a manifest `[[member]]
path = "..."` list). The fleet is fundamentally an *execution* artifact: it exists
to be run.

T45.1 asks for a **roadmap** artifact: a top-level file that names a set of goals
and the `needs` edges between them, loads into a DAG that can be inspected
programmatically, is documented by `kazi schema`, and is validated by `kazi lint`.
The structural core -- nodes with `needs` edges, validated acyclic with resolvable
refs -- is identical to the fleet's. The question this ADR settles: is the roadmap
just a fleet by another name, or a distinct artifact?

## Decision

Introduce the roadmap as a **distinct, declarative artifact** (`Kazi.Goal.Roadmap`),
sibling to a goal-file, NOT a rename of the fleet manifest. The two differ on
three axes that matter:

1. **Edges are CENTRAL, not decentralized.** A roadmap declares every edge in the
   roadmap file itself (`needs` per `[[goals]]` entry). A fleet scatters its edges
   across each member goal-file's `[metadata] depends_on`. The roadmap is
   self-contained: you read the whole DAG from one file without opening any
   member.

2. **Members may be INLINE.** A `[[goals]]` entry references either a goal-file
   `path` OR an embedded `[goals.goal]` goal-set. A fleet member is always a path.

3. **It is DECLARATIVE, not an execution trigger.** The roadmap's surface is
   `kazi schema roadmap` (the shape) and `kazi lint <roadmap>` (validate the DAG:
   cycles, unresolvable refs). It does not, in this slice, dispatch a harness --
   that is the fleet's job.

The roadmap REUSES rather than reimplements the graph work: cycle detection
mirrors `Kazi.Fleet`'s DFS guard (a `finished` memo + an ancestor stack), and
`Roadmap.frontiers/1` delegates to `Kazi.Fleet.frontiers/1` -- the same
goal-level layering `kazi apply --fleet --explain` prints. No new graph algorithm
was written.

## Consequences

- Two artifacts now describe a goal-level DAG. The boundary is: **roadmap =
  declare/inspect/validate; fleet = execute.** A future slice may let `kazi apply`
  take a roadmap directly (lowering it to a fleet); until then they stay separate
  surfaces and this ADR is the map between them.
- The roadmap's cycle error names the FULL cycle chain (every goal id on it),
  which is strictly more informative than the fleet's two-endpoint message; the
  fleet message is unchanged (out of scope for T45.1).
- `kazi schema` now self-describes a third kind of thing: result schemas, provider
  config schemas, and now artifact schemas (`roadmap`). The dispatch chain in
  `Kazi.CLI.execute_schema/1` gained one clause.

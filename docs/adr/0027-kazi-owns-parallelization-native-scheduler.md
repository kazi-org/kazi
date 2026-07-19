# ADR 0027: kazi owns parallelization (a native scheduler over a partitioned goal-set)

## Status
Accepted

## Date
2026-06-24

## Supersedes (in part)
ADR-0026 on the PARALLELIZATION STANCE only. ADR-0026 said the scheduler stays
external (`/claim` + `/apply --pool` is the outer loop that launches the parallel
agents). This ADR moves the scheduler INTO kazi. ADR-0026 is retained as the
INTEROP story (kazi as a good citizen under someone else's orchestrator / a CI
matrix); it is no longer kazi's answer to "how do I parallelize."

## Context

kazi was born to CODIFY the operator's high-productivity workflow: several Claude
Code sessions on one codebase, picking tasks from a plan via `/claim` git-ref
locks (`/apply --pool`), each converging its task to an objective "done." kazi has
codified two of the three pieces:

- the Definition of Done -> machine-checkable **predicates** (ADR-0002);
- the per-task loop -> the **reconcile loop** (observe/dispatch/integrate, ADR-0001).

It also built the SUBSTRATE for the third -- parallelization: graph blast-radius
partitioning (`Kazi.Partition.partition/3`) and leases (`Kazi.Coordination.
PartitionLease`, ADR-0006). But the SCHEDULER -- the thing that partitions a plan,
spawns N agents, assigns each a disjoint partition, and drives them to collective
convergence -- was never built. Verified 2026-06-24: nothing in `lib/` calls
`Partition.partition`/`lease_keys` to spawn agents; the loop is serial BY DESIGN
("rather than forking a parallel reconcile", `loop.ex:76`/`:1010`); concept sec 8
says "one supervised process per active goal." kazi's parallelism therefore ASSUMES
something external launches the N goals -- and that external something is exactly
`/apply --pool` + `/claim`.

Consequence: the heart of the workflow that birthed kazi -- the parallelization --
lives in the operator's personal skills, not in the product. A NEW user gets serial
single-goal convergence from kazi alone but must bring their own orchestrator to
parallelize. That is the unfinished half of the codification, and ADR-0026 (shape a)
cemented it by keeping the scheduler external.

Elixir/OTP makes closing this gap a STRENGTH, not a bolt-on: the domain is "a
supervised population of fallible concurrent processes" (concept sec 8), which is
the BEAM's purpose. A single-node run can coordinate N reconcilers with the
IN-MEMORY lease (`Kazi.Coordination.Lease.Memory`) and a `DynamicSupervisor` -- NO
NATS required; NATS (ADR-0004) is only for the multi-machine case.

## Decision

kazi gains a NATIVE PARALLEL SCHEDULER. `kazi run` on a goal-set:

1. **Partitions by blast radius** (`Kazi.Partition.partition/3` over the graph /
   repo-map) into disjoint partitions -- conflict-free parallelism BY CONSTRUCTION
   (concept sec 9), not just reactive collision detection. A single goal / no graph
   degenerates to one partition (today's serial behavior).
2. **Leases each partition** (`PartitionLease`) for the life of its run. Single-node
   uses the in-memory lease (NATS-free); multi-node uses the NATS lease behind
   config. Residual overlap (a partition's edits expand its radius) serializes on
   the lease.
3. **Spawns one supervised reconciler per partition** under a `DynamicSupervisor`,
   each the EXISTING per-goal serial loop (the serial-single-goal design is
   unchanged; parallelism is ACROSS partitions, each its own reconciler). A
   scheduler/coordinator process tracks terminal states and reports COLLECTIVE
   status (all converged / any stuck / over budget).
4. **Isolates each fixer in its own git worktree** (concept sec 9), then integrates
   with MERGE CONVERGENCE across partitions (disjoint blast radii make conflicts
   rare; residuals re-dispatch the affected partition).
5. **Observes + escalates** via the existing dashboard/presence/lease map (the N
   reconcilers + leases + per-partition convergence) and Telegram.

Single-goal remains the simple no-deps on-ramp; parallelism is OPT-IN scale
(`kazi run --parallel [N]`, or automatic from a multi-partition goal-set). This
makes `/apply --pool` + `/claim` UNNECESSARY for kazi-native parallel work -- the
codification the operator set out to build.

## Consequences

- A new user gets parallelism from `kazi run` alone -- no `/apply`, no `/claim`, no
  personal scripts. kazi's "coordinates parallel agents" value prop is now COMPLETE
  (substrate + scheduler), not half.
- Single-machine parallelism is NATS-free (in-memory lease + `DynamicSupervisor`),
  which fits the operator's setup (one Mac); NATS is reserved for multi-machine.
- kazi's partitioning is SMARTER than `/claim`'s "take next unclaimed task": it
  assigns disjoint blast radii by construction, preventing the silent logical
  conflicts task-locks miss.
- ADR-0001 holds: kazi still drives harnesses and is not one -- it now ORCHESTRATES
  multiple harness dispatches under supervision, which is the outer-loop role taken
  to its conclusion.
- Hard parts (each a planned task): git-worktree lifecycle per partition (disk +
  the worktree-guard landmine), merge convergence across partitions, dynamic-radius
  overlap policy, partition QUALITY depending on graph freshness, and
  supervision/restart that does not corrupt lease/worktree state.
- ADR-0026/E20 are demoted to interop; their L1/L2 (verification gate, good-citizen
  behavior) and L3 (leases) remain useful -- L3's leases are the substrate this
  scheduler consumes.

## Alternatives rejected

- **Keep the scheduler external (ADR-0026 shape a as primary).** Leaves the
  parallelization -- the heart of the founding workflow -- in personal skills;
  new users must bring their own orchestrator. This ADR exists to close that gap.
- **Require NATS for all parallelism.** Unnecessary on a single machine; the
  in-memory lease + `DynamicSupervisor` parallelize in one BEAM. NATS is the
  multi-machine upgrade, not the entry price.
- **A "swarm of fake agents."** Rejected (concept sec 10): concurrency is real
  supervised processes/harness subprocesses under leases, each converging an
  objective partition -- not simulated agents.

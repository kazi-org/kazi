# ADR 0087: kazi plans, the dispatcher schedules, one goal per container

## Status

Proposed (awaiting review by the chief and chief-architect sessions; drafted
from their unanimous verdict of 2026-09-05). Recorded in the fleet's decision
ledger; founder ratification of the layering ruling pending at the next
scheduled sync.

## Date

2026-09-05

## Refines

ADR-0006 (blast-radius leases), ADR-0065 (§1 serial apply as the 1-partition
degenerate case, §3 fleet overlap inference), ADR-0086 (decision 3, the node
render), and the E21 partition scheduler (`Kazi.Partition`,
`Kazi.Scheduler`).

## Context

kazi parallelizes at two grains today. Within one goal-file, E21 groups goals
into partitions by transitive blast-radius overlap (`Kazi.Partition`,
`lib/kazi/partition.ex:119-139` and `:200-228`: one survey per goal, then a
union-find over shared paths) and leases one worktree per partition. Across
goal-files, ADR-0065 §3 builds a fleet DAG from explicit `depends_on` plus
inferred `write_paths` overlap, bounded by the `:fleet_concurrency` semaphore
(`lib/kazi/fleet/execution.ex:144-172`). Both treat any shared path as "never
concurrent", and the union-find is transitive, so one hotspot file
(`mix.exs`, `go.mod`, `docs/plan.md`) chains every goal that touches it into
a single serialized partition.

Two more layers of parallelism exist outside kazi: an operator runs several
harness sessions at once, and the fleet is moving into containers scheduled
by a governed dispatcher (the sibling Sire project, its ADR 0136: Machine,
Job, Lease; one Job is one operation, one claim is one attempt, with
`slot_capacity` per machine). The open question was whether the end state is
parallel containers each running parallel kazi lanes, and which layer owns
the concurrency decision.

ADR-0086 settled how a goal's node reaches an agent (a pure render, never
committed, embedded by the dispatcher in the lane's prompt channel). It did
not settle who decides what runs beside what.

## Decision

1. **kazi plans; the dispatcher schedules and executes; kazi in a container
   runs one goal.** kazi's competence is the goal-file: it emits the nodes,
   the explicit `depends_on` edges, the inferred `write_paths` overlap edges
   (ADR-0065 §3, unchanged), the `shared_paths` lease keys (decision 4), and
   each node's render (ADR-0086 decision 3). The dispatcher's competence is
   the governed unit of work: one fleet node = one Job = one container = one
   attempt, leased, budgeted, approved, receipted (Sire ADR 0136). Inside
   the container kazi runs exactly one goal in serial mode; it never sees a
   fleet manifest and never partitions. Rationale: the governance seam
   (approval, metering, audit) is per Job. Parallelism hidden inside a
   container is work the seam cannot attribute a cost, an approval, or a
   receipt to, and that is the one thing the dispatcher exists to prevent.

2. **Exclusivity by construction, not by a number.** The lane adapter
   dispatches kazi with a `single_node` flag recorded in the lane contract
   beside the task sha; when it is set, kazi refuses `--fleet` and any
   multi-partition apply before dispatch. A goal is partitioned by exactly
   one layer. The goal-file never knows which adapter runs it: the same
   `goal.toml` runs under the interactive adapter (an operator on one
   machine, no dispatcher) with E21 partitions and `:fleet_concurrency` as
   the cap, and under the lane adapter with neither. The interactive path is
   ADR-0065 §1's degenerate case, not a second cap; the fleet-wide cap lives
   in the dispatcher (`slot_capacity` per machine plus dispatch concurrency).

3. **`kazi plan render --dag` exports the DAG as data.** Nodes, edges with
   their kind (`explicit` or `inferred_overlap`), each node's `write_paths`
   and `shared_paths`, and the sha256 of each node's render, in a stable
   serialization the dispatcher imports into Jobs. The document also carries
   the source commit sha it was computed from and a digest of each goal-file,
   so a dispatcher pinning Jobs at a task sha can check that the DAG it
   imports matches the tree it dispatches. The node render sha256 in the
   export is computed at planning time; the dispatcher re-renders at
   dispatch per ADR-0086, so the two hashes are expected to differ once
   observe state moves -- not a bug. Per ADR-0065 §5 the export routes
   through the worktree indirection like every other `plan render`. This is
   the whole interface between the layers; neither reads the other's
   internal state.

4. **`[scope].shared_paths` declares hotspots and turns them into per-file
   lease keys instead of partition merges.** `shared_paths` resolves at
   FLEET level: the effective set is the union of every member goal's
   declaration (or one declaration on the fleet manifest), and the exclusion
   applies symmetrically to every partition survey and to the fleet overlap
   test, so the result cannot depend on which goal is surveyed first. A
   path in one goal's `write_paths` that another goal declares shared is
   fine; a path declared shared by one goal and undeclared-but-written by
   another is exactly the case the union rule covers. A path in the
   effective set is excluded from the blast radius `Kazi.Partition` feeds
   its union-find (`partition.ex:206-228`), so two goals that both touch
   `mix.exs` stay in disjoint partitions, and is likewise excluded from the
   ADR-0065 §3 `write_paths` overlap test in `Kazi.Fleet`. Each shared path
   becomes a lease key. Lease scope differs by adapter, and the difference
   is deliberate: in the interactive adapter kazi's own lease
   (`Kazi.Coordination.Lease`, ADR-0006) is held only around the integration
   step that touches the file, so two partitions grind concurrently and
   serialize on the commit; across containers the dispatcher's lease is
   held for the Attempt's lifetime (a Job has no plane-visible integration
   phase), so in v1 two Jobs sharing a key never run concurrently -- the
   same effect as an overlap edge, with the key recorded for the day a
   phase-scoped release exists. Phase-scoped release across containers is a
   follow-up that needs a container-to-plane phase message and is owned on
   the dispatcher side; this ADR does not define it. Semantic conflict on a
   shared file is already handled by the existing conflict re-dispatch.

5. **`[scope].contract` names a stub or signature file rendered into every
   child node.** Refines ADR-0086 decision 3: the render includes the
   contract's content so children build against the contract, not each
   other's work in progress. `kazi plan lint` refuses a goal whose
   `write_paths` includes its own `contract` path, and refuses a fleet in
   which any child's `write_paths` includes a sibling's contract. Choosing
   the partition stays the planner's judgment; kazi does not split goals
   (ADR-0085: kazi enforces what is declared, it does not infer intent).

**Held, not decided.** A parent goal that converges on
compile-against-contract plus the union of its children's `depends_on`,
children converging concurrently. The convergence semantics are kazi's and
the execution order is the dispatcher's, but compile-against-stub viability
has no evidence yet. Revisit once decisions 4 and 5 have run at least once.

## Consequences

**Positive:**
- The layering question has one answer: no layer parallelizes what another
  layer already parallelized, and the check is a flag the dispatcher records
  and kazi honors, not an operator convention.
- Hotspot files stop serializing whole fleets; the cost of a shared file is
  one lease around one integration step.
- The kazi-dispatcher interface is one exported document, so either side can
  change its internals without the other noticing.

**Negative / accepted trade-offs:**
- **Blocked on the sibling repo:** the dispatcher side (import the exported
  DAG into Jobs, honor `shared_paths` as lease keys, record `single_node` in
  the contract) is the sibling repo's E-FLEETD row for DAG import, minted
  and reviewed there; its dependencies are that repo's ADR 0136 accepted,
  this ADR merged, and a sibling-side DAG-import ADR minted after this one
  merges. This ADR cites that row by id once it lands; neither ADR restates
  the other's rule.
- `Kazi.Partition`'s radius is a survey of impacted files, not the declared
  `write_paths`, which is why decision 4 excludes the effective
  `shared_paths` in two places (the survey radius and the fleet overlap
  test). A hotspot that is impacted but declared shared by no goal still
  merges partitions; declaring it is the fix.
- A lease that serializes only the integration step assumes the agents'
  edits to the shared file are mergeable; when they are not, the existing
  conflict re-dispatch pays the cost that a partition merge would have
  avoided up front.

## Alternatives rejected

- **One container per fleet, kazi partitions inside.** Rejected: the
  governance seam sees one blob and cannot attribute cost or approval to a
  lane, and it puts two schedulers in one process.
- **The dispatcher as an opaque executor that owns all concurrency, kazi
  never in the container.** Rejected: the dispatcher would have to
  reimplement partition semantics (blast-radius union-find, sentinels,
  seals) to make scheduling decisions; those belong where the goal-file is
  parsed.
- **A Job carries `slots = N` and kazi partitions inside it.** Proposed and
  withdrawn by the chief session: it is the first rejected option with a
  number attached, and a number is a weaker exclusivity guarantee than a
  flag kazi refuses to run against.
- **Speculative integration order chosen to minimize conflicts.** Rejected
  for now: the safe order is deterministic by lease key, kazi has no
  conflict predictor, and re-dispatch on residual conflict already bounds
  the cost. Revisit with ADR-0079 velocity data.
- **Automatic `kazi plan split` into disjoint-scope children.** Rejected:
  choosing the partition is the planner's judgment; kazi ships the
  `contract` field and the lint, not the split.

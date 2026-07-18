# ADR 0065: Safe concurrent work -- serial apply owns its working directory; fleets over goal-files

## Status

Accepted

## Date

2026-07-09

## Refines

ADR-0027 (native parallel scheduler: partition worktrees, blast-radius
partitioning, collective integration), ADR-0028 (predicate-graph waves),
ADR-0055 (landing is part of convergence). Responds to issue #937 (the
umbrella proposal filed after a real data-loss incident) -- specifically its
Gap A (full ask) and Gap D. Gap A's tripwires (#940 primary-worktree refusal,
#942 duplicate-run refusal) and Gap B's minimal slice (#936's
`frontier_complete` stream event) already shipped; this ADR covers what
remains structural.

## Context

E21 gave the PARALLEL path real isolation: each partition reconciles in its
own git worktree, integration is collective (branch -> rebase-merge) with
conflict re-dispatch, and overlapping blast radii serialize. None of that
applies to a plain serial `kazi apply <goal> --workspace <path>`: serial
apply trusts `--workspace` completely and edits it in place. Issue #937
records the consequence -- a serial run pointed at a real working checkout
converged correctly, and the dispatched agent's shell still destroyed
unrelated untracked state in that checkout. The #940 guard now REFUSES the
most dangerous target (a primary worktree root), but refusal is a tripwire,
not a capability: the operator still hand-builds a worktree per goal, by
convention, every time.

Separately, real work routinely spans SEVERAL goal-files with cross-file
dependencies. The 2026-07-09 five-goal batch on this repo is representative:
five goals, one worktree each, sequencing and conflict-awareness managed by
hand in an operator session (two goals touching `lib/kazi/authoring.ex` were
merge-ordered manually). E21's machinery -- worktrees, leases, blast-radius
overlap, budget rollup -- operates only WITHIN one goal-file; across
goal-files there is nothing, which is #937's Gap D.

## Decision

1. **Serial apply becomes the 1-partition degenerate case of the parallel
   scheduler.** An executing serial apply routes through the same worktree
   indirection T21.4 built for partitions: kazi creates (and cleans up) a
   task worktree from the `--workspace` ref, the dispatched agent works
   there, and `--workspace` comes to mean "the base I want this goal
   integrated onto" rather than "the directory kazi may mutate". The
   primary-worktree guard (#940) then rarely fires at all -- the dangerous
   target stops being reachable by default. An explicit `--in-place` opt-out
   preserves today's direct-edit behavior for callers who already manage
   their own worktrees (and composes with `--allow-primary-workspace`, which
   stays as the guard's override for the in-place path).

2. **Integration follows T21.5, not a tree-wide landing.** The 1-partition
   path lands its work exactly as a parallel partition does: commits on a
   task branch, integrated onto the base by rebase-merge (or handed off as a
   pushed branch when the goal's `landed` contract says push-only). kazi
   core continues to NEVER run `git reset`/`git clean` against operator
   state (already structurally true -- enforcement graders use throwaway
   detached worktrees; recorded here as a decision so it stays true).

3. **A fleet is a DAG of goal-files, reusing E21 end to end.** `kazi apply
   --fleet <dir-or-manifest>` treats each `*.goal.toml` as a node. Edges
   come from explicit `[metadata] depends_on = ["<goal-id>", ...]`, with
   declared `[scope]` path overlap inferring a serialization edge when no
   explicit edge exists (overlap = same blast radius = never concurrent --
   the same rule E21 applies within a goal-file). Execution reuses the
   partition scheduler one level up: worktree per goal, leases across the
   fleet, pipelined frontier advancement, per-fleet concurrency cap and
   budget rollup (the #343 rollup, scoped one level higher). The
   `frontier_complete` stream event (shipped for waves) generalizes to
   fleet-node boundaries, and the supervised-checkpoint mode #936 asks for
   (`--pause-between-waves` / resumable stop at a boundary) lands here,
   covering both waves-within-a-goal and goals-within-a-fleet with one
   mechanism.

4. **Single node, NATS-free.** Fleet coordination uses the existing shared
   read-model registry (the duplicate-run guard's substrate) -- no new
   coordination dependency. Cross-node fleets remain Slice 3 (ADR-0004)
   territory and are out of scope.

5. **The indirection covers every workspace-mutating verb, and the base
   must be demonstrably fresh.** Decision 1 is not an apply-only rule: any
   kazi verb that writes into a workspace -- an executing apply (serial,
   parallel, fleet), goal-file materialization (`.kazi/goals/`, ADR-0059),
   `kazi plan render` (ADR-0056), a roadmap expansion -- routes through the
   same worktree indirection; kazi core never mutates the caller's checkout
   by default. Separately, isolation without freshness is a quieter bug:
   the worktree machinery cuts from the workspace's HEAD, and a checkout
   parked on a stale feature branch yields an isolated-but-stale base whose
   work integrates only through avoidable conflict re-dispatch (observed on
   this repo: a planning session's checkout was behind origin/main far
   enough that the current ADR was not visible locally). So the base ref is
   explicit and validated: creation defaults to the workspace's HEAD,
   `--base <ref>` (e.g. `origin/main`) overrides, and when the base is
   behind its locally-known upstream kazi WARNS loudly -- never an implicit
   network fetch. The fresh-worktree ritual living in operator skills and
   session lore is exactly the class of convention ADR-0056 requires kazi
   to own.

6. **The workspace itself is guarded against cross-goal co-tenancy, not
   only against same-goal duplication** (T59.7, #937 Gap G). The
   duplicate-run guard (#942/#944) refuses a second live apply of the SAME
   `goal_ref`; it does not notice N DIFFERENT goals dispatched against one
   shared `--workspace`, whose agents cross-contaminate each other's commits
   (the commit-bleed incidents in #937). So an executing apply also refuses
   to start when a LIVE run for a DIFFERENT goal already holds the resolved
   working directory, reusing the SAME fresh-heartbeat liveness the
   duplicate-run guard trusts (`RunRegistry.list_live/0`) -- a stale/dead
   holder never blocks, aging out within ~90s. `--allow-workspace-collision`
   is the explicit override, mirroring `--allow-duplicate-run`. This is the
   backstop for callers who still pass an explicit shared `--workspace`; the
   default per-run task worktree (decision 1) already keeps two goals off one
   directory, so in the common case the guard never fires.

## Consequences

Positive: the data-loss class #937 documents becomes structurally
unreachable by default instead of merely refused; the operator's manual
worktree-per-goal ritual (five times in one night on this repo) becomes
kazi's job; #936's full checkpoint ask gets a natural home; fleet metrics
aggregate under the ADR-0058 economy envelope for free (runs already record
per-goal).

Negative / accepted costs: worktree creation adds per-run setup cost on the
serial path (measured in E49 before default-flip -- the ADR-0047 discipline);
`--workspace` semantics change is a behavior break for callers relying on
in-place edits (mitigated by `--in-place` and a deprecation window);
scope-overlap inference can over-serialize a fleet whose goals share broad
`[scope]` globs (explicit `depends_on = []` edges and narrower scopes are
the escape hatch); the staleness warning can nag a caller who deliberately
pins an old base (mitigated: `--base` states intent and silences it, and it
is a warning, never a refusal).

## Alternatives rejected

- **Keep the tripwires and stop.** Refusal without capability leaves every
  operator re-implementing worktree discipline by hand; the incident class
  returns the first time someone passes the override under time pressure.
- **A separate fleet orchestrator outside kazi.** Rejected on the ADR-0056
  one-system grounds; the scheduler, leases, and registry already exist
  in-core, and an external orchestrator cannot see blast-radius overlap.
- **Docker/VM sandboxing instead of worktrees.** Heavier, slower, breaks
  local toolchains, and solves isolation kazi already gets from git
  worktrees at near-zero cost.

Implementation is epic E49 (docs/plans/E49.md).

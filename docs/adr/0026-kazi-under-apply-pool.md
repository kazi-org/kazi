# ADR 0026: kazi under /apply --pool (objective-done + coordination layer beneath pooled sessions)

## Status
Accepted

## Date
2026-06-24

## Context

The operator runs several Claude Code sessions on ONE codebase via `/loop /apply
--pool`: each session picks an unclaimed task from `docs/plan.md` using `/claim`
atomic git-ref locks (`refs/claims/*` -- task ids plus `R-<slug>` shared-file
locks), does the work, opens a PR, and rebase-merges. This is a high-productivity
workflow, but it is a HAND-ROLLED version of kazi's own problem statement --
parallel agents converging a plan with trustworthy "done" and resource
coordination -- and it carries three documented failure modes (see the operator's
CLAUDE.md):

- **Session-asserted done.** Each session decides when its task is finished; "done"
  is the agent's opinion, enforced only by a prose Definition of Done. This has
  produced FALSE completions (a subagent reported a PR merged when it was not).
- **Wave stalls.** Waves stall at ~5-of-10 on auth/push/test failures, with no
  self-recovery -- a stalled session dies silently rather than escalating.
- **Coordination too coarse.** `/claim` locks a TASK id (and named files), not the
  actual code a task touches. Two different tasks can edit the SAME function, both
  rebase-merge clean, and break behavior -- a silent logical conflict.

kazi already ships the primitives that address each: objective termination (done
lives in the controller, evidence-backed), the reconcile loop with stuck/regression/
flake/budget guards, blast-radius leases (`Kazi.Partition` + `Kazi.Coordination.
PartitionLease`, ADR-0006), an agent-drivable JSON CLI (`propose --json
--predicates` caller-drafts + `run --json`, ADR-0023), and live observability
(dashboard + presence + lease map + Telegram). The question is HOW kazi integrates
with the pool. Two shapes were considered: (a) kazi UNDER each pool session
(objective-done + coordination + observability beneath the sessions you already
run), and (b) kazi REPLACES the pool scheduler (the plan becomes a kazi goal-set
kazi schedules across a swarm). We choose (a); (b) is deferred (kazi does not yet
own task scheduling across a swarm).

## Decision

Integrate kazi UNDER each `/apply --pool` session (shape a). Specifically:

1. **Two-tier coordination, composed, not replaced.** `/claim` remains the OUTER
   coordination -- which session takes which task (task ids + shared-file `R-`
   locks). kazi's blast-radius leases become the INNER coordination -- what code a
   task's execution may touch. The boundary is explicit: claim = task selection
   (acquired first), lease = blast radius (acquired by the kazi run). Neither layer
   is removed; they compose at different granularities.

2. **The authoring bridge is caller-drafts, the single authoring path.** A pool
   session converts its plan task's `acc:` line into predicates and supplies them
   via `kazi propose --json --predicates <json>` (ADR-0023): kazi applies the
   deterministic floor + persists, spawning NO inner model. `kazi run --json` is
   then the execution + objective-done gate. No parallel authoring mechanism.

3. **Layered adoption, each layer independently valuable:**
   - **L1 -- Verification gate.** Run the task's predicates as the MERGE gate;
     a PR lands only when kazi reports `converged` (incl. a live probe). Replaces
     "trust + CI."
   - **L2 -- Objective done + convergence loop per task.** The session becomes the
     orchestrator (claude -> kazi -> cheap/claude): observe failing predicates ->
     dispatch -> re-observe, with guards; optionally tier the inner loop to a
     cheap/local harness.
   - **L3 -- Blast-radius leasing across sessions.** Each kazi run leases its
     task's blast radius; overlapping radii serialize, disjoint run free.
   - **L4 -- Shared observability + direction.** Point the dashboard/presence/lease
     map at the live pool; declare/approve + get pinged via Telegram.
   L1-L2 work with git-refs only; **NATS (ADR-0004) is required only at L3.** This
   keeps the on-ramp cheap and defers the NATS dependency to the layer that needs it.

4. **Objective done replaces session-asserted done for opted-in tasks** -- killing
   the false-completion class and turning a stalled task into a reported `stuck ->
   escalate` instead of a silent death.

5. **/apply --pool is NOT replaced.** ADR-0001 holds: kazi is the outer loop for
   the harness, never a harness; here it is the inner CONTROLLER beneath the
   session-as-orchestrator. The global `/apply` skill may grow an opt-in
   `--verify-with-kazi` gate (enhanced globally per the skills policy, cross-repo),
   but the kazi repo owns the enablers + the recipe.

## Consequences

- The exact documented pool failure modes are hardened: false-completion (L1/L2
  objective done), wave stalls (loop + guards + stuck-escalation), silent logical
  conflicts (L3 blast-radius leases finer than task locks).
- Value lands incrementally without an up-front NATS dependency (L1/L2 git-refs
  only); the deeper coordination + observability arrive at L3/L4.
- A new contract exists -- the `/claim` <-> kazi-lease compose-boundary -- which
  MUST be deadlock-safe (acquire order, lease TTL, release ordering); it is its own
  task with tests.
- A cross-repo coupling: the opt-in gate in the global `/apply` skill must stay in
  sync with kazi's CLI (the same drift risk as the README<->site / skill coherence
  guards); kazi's `help --json` is the source of truth.
- The pool can run cheaper via per-task model tiering (L2), gated honestly by
  local-model speed (devlog T8.11 / 2026-06-24).

## Alternatives rejected

- **Shape (b): kazi replaces the pool scheduler now.** kazi does not yet own task
  scheduling across a swarm the way `/apply --pool` + `/claim` do; adopting (b) now
  would rebuild a working scheduler. Deferred to a future ADR once kazi owns
  plan-level scheduling.
- **Replace `/claim` with kazi leases wholesale.** Loses the simple git-ref task
  selection that needs no NATS; the two systems compose better at different
  granularities (claim = task, lease = blast radius) than either does alone.
- **A parallel predicate-authoring path for the pool.** Violates ADR-0023's single
  authoring path; use `propose` caller-drafts.

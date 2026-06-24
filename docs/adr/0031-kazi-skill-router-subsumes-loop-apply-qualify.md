# ADR 0031: The kazi skill as a router; kazi run subsumes loop/apply/qualify for code goals

## Status
Accepted

## Date
2026-06-24

## Builds on
ADR-0024 (kazi self-teaching: the `kazi install-skill` Claude Code skill),
ADR-0027 (native parallel scheduler), ADR-0028 (predicate-graph waves). Those made
kazi a native reconcile loop with parallel, ordered, objectively-gated execution.
This ADR restructures the human/agent-facing SKILL so the operator's workflow
collapses onto it.

## Context

The operator's high-productivity workflow is a hand-assembled outer loop of five
Claude Code skills: `loop -> plan -> apply -> tidy -> qualify` (typically
`/loop /apply --pool`). That pipeline IS a reconcile loop -- exactly what kazi was
born to be. After ADR-0027 (E21 scheduler) + ADR-0028 (E23 waves) + objective
predicates (ADR-0002) + standing mode, kazi performs the loop natively: author
predicates -> partition by blast radius -> drive N supervised reconcilers in
dependency-ordered waves -> stop at objectively-true / stuck / over-budget ->
re-converge on drift.

So most of the five skills now live INSIDE `kazi run`:
- **loop** -- the reconcile loop is internal; `--standing` re-converges on drift.
- **apply** -- the native scheduler (E21) + `needs`-edge waves (E23) ARE parallel
  wave execution; blast-radius leases are finer than `/claim`'s task locks.
- **qualify** -- "launch-ready" is not a heuristic to infer (coverage+verify); it is
  the predicate vector being satisfied WITH evidence, including a live prod probe.
  Objective done = qualification, by definition.

Two do NOT collapse:
- **plan** -- kazi's `propose` drafts PREDICATES, but not the strategic narrative the
  operator relies on (ADRs, use-case linkage, the human-readable WBS). That is human
  judgment about WHAT to build.
- **tidy** -- git/worktree/scratch hygiene is orthogonal to predicate convergence.

The current `kazi` skill (ADR-0024) teaches a flat recipe. The operator wants it
restructured into sub-skills so the workflow has one front door.

## Decision

1. **Restructure the global `kazi` skill (`~/.claude/skills/kazi/`) as a ROUTER with
   sub-skills.** Sub-skill names are the operator's HUMAN verbs (matching their
   existing skill vocabulary); each drives a real `kazi` CLI command underneath (the
   skill verb need not equal the CLI verb -- e.g. `plan` -> `propose`, `apply` ->
   `run`):
   - `kazi plan <idea>` -- author/refine the goal-set (predicates + `[[groups]]` +
     `needs` edges). Drives the single authoring path `kazi propose --json`
     caller-drafts (ADR-0023): the agent that already reasoned supplies the draft;
     the deterministic floor + approve gate apply.
   - `kazi apply [--parallel] [--standing]` -- converge the goal-set via the native
     scheduler (E21/E23). Named `apply` for continuity with the operator's `/apply`
     (it is the native replacement); drives the `kazi run` CLI command. SUBSUMES
     `apply` and `loop` for code goals.
   - `kazi status` / `kazi watch` -- convergence state / the LiveView dashboard;
     replaces eyeballing N pool sessions.
   - `kazi adopt <repo>` -- reverse-engineer a starter goal-set (`kazi init`).
   - There is NO `kazi qualify` sub-skill: a read-only `kazi apply --explain` (CLI
     `kazi run --explain`) evaluates predicates WITHOUT dispatching, so qualification
     is a facet of apply, not a separate skill.

   NAMING: the SKILL verbs (`plan`/`apply`/`status`/`adopt`) are chosen for the
   operator's muscle memory; the CLI verbs (`propose`/`run`/`status`/`init`) are the
   real shipped commands and stay unchanged. `kazi run` is NOT renamed -- only the
   skill that fronts it is called `apply`.

2. **Retire `loop` and `qualify` for CODE goals.** They fold into `kazi apply` (CLI
   `kazi run`). They remain available as general skills for non-code use; the kazi
   on-ramp simply does not route to them.

3. **Re-seat `/plan`, do NOT fold it.** `/plan` stays the strategy/intent-authoring
   layer (ADRs, use cases, the WBS) and its output for a code goal is (or emits) a
   kazi GOAL-SET -- predicates + groups + `needs` edges. The seam is explicit:
   `/plan` authors intent; `kazi run` executes + verifies it. `kazi plan` is the thin
   predicate-drafting front door; `/plan` is the deeper strategic layer that can feed
   it.

4. **Keep `/tidy` as hygiene**, orthogonal to kazi. Optionally `kazi run` triggers a
   post-converge plan-trim, but branch/worktree/scratch sweeping stays in `/tidy`.

5. **Scope = ENGINEERING/code goals only.** Non-code work (content, GTM, ops) still
   uses `/plan` + `/apply` + `/crew` with work-type profiles. kazi does not claim
   those.

6. **Gate the "kazi run replaces /apply --pool" messaging on PROOF.** The skill
   restructure ships, but the claim that `kazi run --parallel` supersedes the manual
   pool is asserted publicly only once the E21/E23 live dogfoods (T21.12, T23.9)
   pass. Until then the router offers `kazi run --parallel` as the path and
   `/apply --pool` stays the documented interop fallback (ADR-0026).

7. **Coherence-guarded.** Sub-skill content references only real `kazi` commands,
   enforced by the existing skill<->CLI coherence test (T16.4) and `kazi help --json`
   as the source of truth.

## Consequences

- The operator's five-skill loop collapses to two front doors for code goals:
  `kazi plan` (author intent) and `kazi apply` -> CLI `kazi run` (apply + loop +
  qualify as one declarative, objectively-gated act). Big reduction in glue.
- The launch gate becomes objective (predicates incl. live) instead of qualify's
  inferred verdict -- the founding no-false-done thesis applied to the operator's
  own workflow.
- Self-healing via standing mode replaces manual re-qualify after every change.
- `/plan` keeps producing the human-readable strategy + ADRs; nothing about the
  planning discipline this project runs on is lost.
- The skill is GLOBAL, so the restructure benefits every project -- and must not
  hardcode kazi-only assumptions that break a non-kazi repo (the router degrades to
  "kazi not installed -> use /plan + /apply" cleanly).
- Risk: asserting subsumption before the dogfoods prove it would overclaim;
  Decision 6 gates the messaging. Risk: a brand-new router that drifts from the CLI;
  T16.4 coherence + `help --json` generation mitigate.

## Alternatives rejected

- **Leave the kazi skill as a flat recipe (ADR-0024 status quo).** Does not give the
  operator the plan/run front doors they asked for; keeps the 5-skill glue manual.
- **Fold `/plan` entirely into `kazi propose`.** Loses the strategic narrative
  (ADRs, use cases, WBS) the operator depends on; `propose` drafts predicates, not
  strategy. Re-seat, do not delete.
- **Delete `loop`/`qualify`/`tidy` globally.** They serve non-code and
  repo-hygiene work kazi does not cover; retire them only from the CODE-goal on-ramp.
- **Make qualify a first-class `kazi qualify` sub-skill.** Redundant -- a read-only
  `kazi run`/`--explain` over the predicate vector IS qualification; a separate skill
  would re-introduce a heuristic layer kazi exists to remove.

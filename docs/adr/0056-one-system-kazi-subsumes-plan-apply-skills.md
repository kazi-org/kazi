# ADR 0056: One system — kazi subsumes the operator's plan/apply orchestration skills for engineering work

## Status
Accepted

## Date
2026-07-03

## Refines / supersedes
Extends ADR-0031 (the subsumption claim — there scoped to loop/apply/qualify,
here extended to the WHOLE plan→apply orchestration surface, still gated on
proof). **Supersedes ADR-0035 decision 1 in part**: the escalation-ladder
POLICY location moves from orchestration-skill prose into the goal-file as
DATA (`[escalation]`); the core principle survives unchanged — kazi-core still
contains no model-selection logic, it only reads a declared rung list. Marks
ADR-0026 (kazi as a good citizen UNDER an external pooled orchestrator) as the
transitional posture: it becomes historical once this ADR's exit proof passes.
Builds directly on ADR-0055 (landing is part of convergence), ADR-0027/0028
(native scheduler, predicate-graph waves), ADR-0036 (doc lifecycle as a
standing goal), ADR-0052 (self-teaching artifacts, no personal-skill
assumptions), ADR-0054 (use cases are Gherkin).

## Context

Before kazi, the operator ran engineering work through a pair of
orchestration skills — a `/plan` skill (WBS authoring: epics, tasks,
dependencies, waves, acceptance lines) and an `/apply` skill (pooled parallel
execution: claims, worktrees, teammate discipline, merge protocol, ship
chain). kazi grew alongside them, and every time a piece of that
orchestration proved valuable it was ported into kazi by ADR: objective
predicates (ADR-0002), the native scheduler replacing the pool (ADR-0027),
computed waves replacing the hand-authored Waves section (ADR-0028), Gherkin
use cases replacing the manifest (ADR-0054), doc lifecycle as a standing goal
(ADR-0036), and finally landing, the process contract, gate providers, and
preflight (ADR-0055/E44).

The result is two parallel systems maintaining copies of the same facts:

| orchestration-skill piece            | kazi twin                                     |
|--------------------------------------|-----------------------------------------------|
| task `acc:` lines                    | goal-set predicates (bridged by copying)       |
| hand-authored Waves section          | the `needs`-DAG schedule (`apply --explain`)   |
| pool claims + worktrees              | scheduler partitions, leases, worktrees        |
| ship chain (PR→CI→merge→deploy→live) | decide clauses 3–5 + E44 integrate/deploy      |
| teammate discipline prompts          | the E44 process contract                       |
| docs/OSS/stub wave gates             | E44 gate providers                             |
| preflight                            | E44 preflight                                  |
| checkpoint files                     | the read-model + `kazi status`                 |
| use-case manifest JSON               | Gherkin scenarios via `kazi spec import`       |

Prose copies drift; ~1,800 lines of orchestration prose live outside any test
or release process, maintained by one operator, while kazi's half is
versioned, ExUnit-pinned, coherence-guarded (ADR-0052), and shipped by
release. The operator's requirement is explicit: ONE way of doing things, one
set of tools to maintain.

What kazi genuinely lacks for full subsumption (everything else above is
already ported or landing via E44):

1. **Roadmap-scope planning.** `kazi plan` authors one goal; a project is an
   ordered SET of goals with dependencies between them, planned rolling-wave
   (deep on the frontier, deferred beyond it).
2. **Discovery as an authoring on-ramp.** Stack detection (`kazi init`) and
   use-case discovery (`init --discover`, ADR-0054) exist as fragments; there
   is no unified understand-before-authoring pass on the plan verb.
3. **The human-readable plan document.** The read-model holds the facts but
   only `status`/dashboard render them; operators read a plan file.
4. **A home for the escalation ladder** once the skill that owned it
   (ADR-0035) retires.

And one thing kazi should NOT absorb: non-engineering work. Content, GTM,
strategy, and operations verification is irreducibly subjective; forcing it
into predicates yields fake objectivity (word counts standing in for quality)
or an LLM-judge provider that reintroduces exactly the gameable
plausible-but-wrong declarations kazi exists to eliminate.

## Decision

**1. Roadmap scope: a project plan is a goal DAG.** `kazi plan --project`
authors (caller-drafts first, per ADR-0023) a ROADMAP: a set of goal
proposals joined by `needs` edges between goals — the same dependency
structure the scheduler already runs within a goal-set (ADR-0028), lifted one
level. `kazi apply` over a roadmap schedules whole goals in `needs` order and
reports a roadmap-level collective verdict; `kazi status` renders roadmap
state.

**2. Rolling-wave planning is native: an outline phase is a GOAL.** Beyond
the frontier, a phase is represented as an outline goal whose predicate is
deterministic and read-model-checkable: "phase N's goal-set exists, passed
the clarify floor, and is approved." Planning itself becomes convergeable
work — a standing `kazi apply` over the roadmap triggers the phase-N+1
planning pass automatically when phase N's goals converge, and each pass is
informed by what execution just learned. Depth follows the frontier by
construction, not by prompt discipline.

**3. The plan document is a generated VIEW.** `kazi plan render` emits the
human-readable plan (WBS with checkboxes, waves, progress) from the
read-model. It is output, never input — regenerated, never hand-edited — so
the document cannot drift from the truth it renders. The read-model (goals,
proposals, predicates, verdicts) is the single source of truth for
engineering work.

**4. Discovery folds into the plan verb.** `kazi plan --discover` runs the
unified on-ramp: deterministic stack detection, use-case discovery
(ADR-0054), and a codebase scan (kazi-drafts mode) whose findings feed the
draft. Caller-drafts mode remains the primary path — a frontier session that
already reasoned about the goal supplies the roadmap and kazi spawns no
second model. The two-tier economics is unchanged: judgment stays in the
orchestrating session; kazi validates, persists, schedules, executes, and
holds the bar.

**5. The escalation ladder becomes goal-file DATA.** An `[escalation]` block
declares the rung list (default `claude-haiku-4-5` → `claude-sonnet-5` →
`claude-opus-4-8`, capped at the frontier) and the step-up trigger
(stuck/over_budget on the same failing predicate set, per the T30.3 signal
mapping). The loop reads the next rung instead of terminating, bounded
exactly as ADR-0035 bounded the skill-side ladder (each rung is one bounded
converge; the ladder is finite). kazi-core still holds NO selection policy —
the ladder is declared configuration, not inference. Pinning a single
`--model` (or omitting the block) degenerates to static tiering, unchanged.

**6. Non-engineering work is explicitly OUT.** kazi claims the engineering
lifecycle end to end; content/GTM/strategy/operations stay on generic
orchestration tooling. One way of doing things per KIND of work: software =
kazi; non-software = whatever generic orchestration the operator prefers.
This is a scope commitment in the ADR-0048-exclusions tradition, not a
deferral.

**7. Retirement is gated on proof (the ADR-0031 discipline).** The
self-teaching artifacts (`kazi install-skill`, `AGENTS.md`) grow to cover the
FULL engineering surface — roadmap planning, discovery, landing, escalation,
status — so any harness on any machine gets the whole workflow from the
binary alone (ADR-0052: no personal-skill assumptions). The operator-side
plan/apply skills retire for engineering repos ONLY after the exit proof: an
engineering slice goes idea → discover → project plan → approve → apply →
landed PRs → live verification with ZERO orchestration-skill involvement,
evidence recorded. Until that dogfood passes, the external skills remain the
documented fallback (ADR-0026 posture), exactly as ADR-0031 held its
subsumption claim until E21/E23 proofs.

## Consequences

Positive: one system — the WBS, waves, ship chain, discipline, and status all
live in kazi, versioned with releases, pinned by tests, coherence-guarded,
installable anywhere the binary goes; the acc:-line copy-bridge and the
hand-maintained Waves section disappear (facts are stored once and rendered,
not duplicated); rolling-wave planning stops depending on planner prompt
discipline because deferred phases are goals the controller schedules;
multi-session pool coordination is retired rather than ported (one
`kazi apply --parallel --standing` process replaces N pooled operator
sessions); the plan document can no longer lie.

Negative / costs: the read-model becomes load-bearing state for PLANNING, not
just runs — its durability and migration story must hold (it already persists
proposals; roadmaps raise the stakes); `plan render` must be good enough that
operators never feel the urge to hand-edit the rendered file (an edit there
is lost work by design and must be loudly documented); ADR-0035's
skill-owned-ladder language is now partially historical and the tiering docs
must be updated in lockstep (the T30.5 coherence guard applies); migrating
kazi's own live WBS to a roadmap goal-DAG is a real cutover with rollback
risk and is sequenced as its own gated task, after the mechanism is proven on
a fixture; non-engineering work intentionally stays outside kazi, so the
operator keeps generic tooling for it — "one system" means one system for
software, not one system for everything.

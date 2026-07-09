# ADR 0059: Goal-file lifecycle -- a conventional directory, sequence-numbered chronology, and archive-on-converge

## Status

Accepted

## Date

2026-07-07

## Context

Materialized `.goal.toml` files accumulate in a repo with no consistent home,
no chronological ordering, and no lifecycle. This session alone put goal files
in three different places: `priv/examples/` (curated dogfood fixtures, fine),
an ad hoc `.kazi/goals/` directory used once in a prior session
(`issue-805-check-mode.goal.toml` and four siblings, plus a `gen_goals.py`
generator, per that session's own memory trail), and a scratch directory
outside the repo entirely (this session's six monitoring-derived goals). None
of these locations is wrong on its own, but their inconsistency IS the
clutter: an operator has no way to answer "what goal files exist, in what
order were they authored, and which are still live" without reconstructing it
by hand each time.

A second, deeper problem sits underneath the file-organization question.
Caller-drafted proposals (`kazi plan --json --predicates`) hardcode `goal_id`
to the literal string `"caller-supplied-predicates"` for every draft (filed as
issue #793). Each new caller-drafted plan silently overwrites the previous
proposal via `ON CONFLICT (proposal_ref) DO UPDATE`, destroying prior
proposals -- including already-approved ones -- with no warning. A
file-naming or archive scheme built on top of colliding identities inherits
the bug: two goals with distinct filenames could still collide in the
read-model the moment they're planned via caller-drafts.

This repo already solved an analogous sprawl problem for a different
artifact. `docs/plan.md` had the same failure mode -- an ever-growing list of
epics with no way to tell live from done -- and ADR-0036 fixed it with three
layers: a master index that points at per-epic files instead of inlining them,
deterministic archival of fully-done epics to `docs/plans/archive/` with a
one-line pointer left behind, and the whole lifecycle run as a kazi STANDING
goal (`priv/examples/doc_lifecycle.goal.toml`) so kazi dogfoods managing its
own doc sprawl. That pattern transfers directly to goal files.

## Decision

### 0. Fix issue #793 first (prerequisite)

Caller-drafts goal-id derivation must honor a payload-supplied `id`/`name`
field, or salt the ref with a content hash when absent, instead of the
hardcoded `"caller-supplied-predicates"` literal. `kazi plan` must refuse (or
loudly warn, never silently overwrite) when a proposal ref already holds an
APPROVED proposal, mirroring the existing `--replace` guard for the
non-caller-drafts path. No goal-file organization scheme is built before this
lands -- a naming convention cannot compensate for identities that collide
underneath it.

### 1. A conventional directory: `.kazi/goals/`

kazi's own code, not operator convention, owns where a materialized goal-file
lives. `kazi plan` gains a `--materialize` flag (or materializes by default
once #793 is fixed and collisions are safe) that writes the approved/drafted
goal as a TOML file under `.kazi/goals/` in the target workspace, instead of
leaving the operator (or an orchestrating agent) to hand-pick a location every
time. `priv/examples/*.goal.toml` stays OUTSIDE this lifecycle entirely --
those are curated, permanent documentation fixtures, not live operator work,
and this ADR does not touch them.

### 2. Sequence-numbered filenames for chronology

Every materialized goal-file gets a strictly incrementing sequence prefix
assigned by kazi at materialize time, e.g. `0001-heartbeat-ticker.goal.toml`,
`0002-bounded-logging.goal.toml` -- read the highest existing prefix under
`.kazi/goals/` (including its `archive/` subdirectory, so the counter survives
archiving) and increment. This mirrors the numbering convention this repo
already uses for ADRs and Ecto migrations, is immune to clock-skew/timezone
ambiguity (unlike a date prefix), and makes a plain `ls` answer "what order
were these authored in" with zero tooling.

### 3. Archive-on-converge, triggered by `kazi apply`'s own terminal signal

When `kazi apply <goal-file>` returns a terminal result with `status:
"converged"` AND the goal-file it was given lives under `.kazi/goals/`
(not an arbitrary path), kazi moves that file to `.kazi/goals/archive/` and
appends one line to `.kazi/goals/INDEX.md`: sequence number, goal name, the
convergence date, and (best-effort, non-blocking) a PR URL if the `landed`
predicate's evidence names one. This is a LOCAL, network-free signal --
kazi already computes it as part of every `apply` call, so no GitHub
dependency or extra polling is introduced. The accepted tradeoff: a goal that
converges by predicate but whose PR is later rejected or reverted in review is
still archived optimistically; the index line stays, but a human can always
un-archive (move the file back) if that happens. This mirrors how ADR-0036
Layer 1 archives an epic on a deterministic, local signal (release-tag
coverage) rather than waiting on a slower or externally-dependent one.

### 4. New CLI surface: `kazi goals`

- `kazi goals list [--status live|archived|all]` -- render `.kazi/goals/` plus
  `INDEX.md` as a single chronological view, live and archived goals together
  by default.
- `kazi goals archive <ref>` -- the manual override, for a goal an operator
  wants to retire without running it through `apply` again (e.g. abandoned,
  superseded).
- The auto-archive behavior of Decision 3 is wired into `kazi apply`'s
  terminal-result handling, not a separate step an operator must remember to
  run.

This is a kazi CORE feature -- it lives in `lib/kazi`, ships in the released
binary, and is available to every repo that adopts kazi, not a per-repo
convention an operator documents and hopes to remember to follow by hand.

### 5. No change to the read-model's own proposal lifecycle

`proposed` / `approved` / `rejected` status in the SQLite read-model is
unchanged by this ADR. This decision is about the FILE artifact a goal
materializes to, not a redesign of the authoring/approval flow itself.

### 6. No auto-migration of existing ad hoc goal-file directories

An existing `.kazi/goals/` directory from before this ADR (flat, unnumbered,
no index) is not automatically rewritten. A one-time, operator-run backfill
script MAY be built later to assign sequence numbers and an initial
`INDEX.md` to a pre-existing directory; it is out of scope here.

## Consequences

Positive:

- One canonical, kazi-owned location per repo for materialized goal files --
  ends the location-drift this very session demonstrated (three different
  places used across three sessions).
- Chronological order is free and unambiguous (sequence prefix), directly
  answering the operator pain point that motivated this ADR.
- The live directory stays small over time via archive-on-converge, the same
  win ADR-0036 already proved for `docs/plan.md`.
- No GitHub/network dependency for the archive trigger -- fully local,
  fully inspectable via git history.
- Fixes a previously-filed, real bug (#793) as a load-bearing prerequisite
  rather than leaving it to rot underneath a new feature.

Negative / accepted costs:

- A goal archived on predicate-convergence can still have its PR rejected or
  reverted later; the archive is optimistic, not merge-confirmed. Manual
  un-archive is the escape hatch.
- New CLI surface (`kazi goals list` / `kazi goals archive`) is a permanent
  addition to kazi core to build and maintain.
- Pre-existing ad hoc `.kazi/goals/` directories in other repos are not
  auto-migrated; adopting this convention there requires either a future
  backfill tool or starting fresh.

Extends ADR-0036 (the direct precedent: master index + deterministic archive
+ standing-goal-driven lifecycle, applied here to goal files instead of
plan/doc epics). Depends on ADR-0023 (caller-drafts) being made collision-safe
via the #793 fix before Decision 1 is implemented.

## Accepted 2026-07-09

The convention was already in operational use in a downstream repo (blink)
ahead of formal acceptance here, and that use surfaced a gap this ADR never
addressed: `.kazi/` was already blanket-`.gitignore`d in every repo kazi
touches, for a different reason entirely (T4.4/ADR-0010's per-dispatch
orientation pack + `.mcp.json`). The blanket rule silently swallowed
`.kazi/goals/` too -- new goal-files and an entire `archive/` subdirectory (22
files in blink) were falling through `git add -A` with zero warning, some
never once captured in git history. Fixed in both repos by narrowing the
ignore to `.kazi/*` + an explicit `!.kazi/goals/` re-include, so the ephemeral
per-dispatch artifacts stay ignored while the durable convention this ADR
defines stays tracked. Any repo adopting this convention should carry the same
gitignore shape, not a bare `.kazi/` rule.

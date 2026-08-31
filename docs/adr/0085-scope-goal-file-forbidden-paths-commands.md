# ADR 0085: `[scope]` goal-file block -- forbidden_paths and forbidden_commands as enforced guard predicates

## Status
Accepted

## Date
2026-08-30

## Context

Two independent live incidents (issues #1695 and #1704) show the same
structural gap. In #1695, a converging grind loop -- given a predicate brief
whose prose explicitly excluded `docs/plan.md`, `docs/plans/<epic>.md`, and
`docs/roadmap.md` as "the orchestrator's to edit, in a fresh judgment, after
convergence" -- committed a change to two of those three files anyway, as
part of its own convergence stack. In #1704, an orchestrating session told
its dispatched sub-agent not to open a PR (converge-and-stop only, no
`--integration`); the grind model, running under `--permission-mode
bypassPermissions` with ambient `gh` credentials, opened one anyway and
wrote a docs file referencing it.

Both exclusions were communicated only in prose -- the human-authored
dispatch brief in #1695, the orchestrating session's own conversation (never
seen by the grind model) in #1704. Per `kazi/AUTHORING.md`, the dispatch
prompt IS the goal name + failing predicates + evidence; the grind model
never sees the orchestrator's session or strategy doc. Nothing in the
predicate vector, the guard set, or `kazi apply`'s own preflight represents
"these paths are off-limits" or "these actions are forbidden" as a checkable
condition, so an otherwise-correct, otherwise-honest convergence can silently
cross a real process boundary with zero signal until a human notices by
reading the commit list or repo state directly by hand.

This is the same class of problem ADR-0055's `[integration]` block and
ADR-0042's read-only predicate/test leasing already solve for their own
narrower cases (landing mode, predicate-file tamper resistance) --
declarative, controller-enforced boundaries beat prose instructions the
grind model may or may not honor.

## Decision

Add an optional `[scope]` block to the goal-file schema with two fields:

- `forbidden_paths` -- a list of path globs the grind loop's own commit
  tooling refuses to touch. Enforced as an automatic guard predicate,
  evaluated the same way `no_stubs`/`oss_hygiene` (ADR-0055) already are: a
  commit that touches any path matching the list fails the guard, and the
  landing/Integrate action itself refuses to include it (not merely
  detect-after-the-fact).
- `forbidden_commands` / `no_integration` -- a declared negative-action
  contract (e.g. "no `gh pr create`/`gh pr edit` invoked during this run",
  "no `--integration` landing"). `no_integration` reuses the existing
  `[integration]` block's `none` mode as its enforcement primitive rather
  than inventing a second landing-mode surface; `forbidden_commands` is
  advisory-checked where mechanically detectable (dispatch-transcript
  command scan) and always documented as best-effort, never claimed as a
  hard sandbox -- `bypassPermissions` grants real shell access this ADR does
  not attempt to revoke.

Both fields are goal-file DATA, not kazi-core policy (consistent with
ADR-0035/ADR-0056's no-policy-in-core line): kazi enforces what is
DECLARED, it does not infer intent. An orchestrating session that wants a
constraint honored must author it into the goal file's `[scope]` block --
this ADR makes that the one channel that actually reaches the grind model,
and closes the silent-scope-creep gap by making violation a guard-predicate
failure instead of an unenforced prose ask.

## Consequences

**Positive:**
- Closes #1695 and #1704 with one mechanism instead of two bespoke fixes.
- Extends the existing guard-predicate enforcement pattern (ADR-0042,
  ADR-0055) rather than adding a new enforcement code path.
- `AUTHORING.md` gains a concrete, mechanical answer to "how do I stop the
  grind model from doing X" instead of "write it in prose and hope."

**Negative / accepted trade-offs:**
- `forbidden_commands` cannot be a hard sandbox without revoking the shell
  access `bypassPermissions` intentionally grants; the ADR is explicit that
  it is best-effort detection, not prevention, for anything beyond the
  landing/`[integration]` and file-path cases it can enforce structurally.
- Adds one more optional goal-file block or authors to learn; mitigated by
  keeping it OPT-IN (absent `[scope]` changes nothing) and documenting it
  next to the existing `[integration]` block it partially reuses.

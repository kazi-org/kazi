# ADR 0019: Interactive clarify phase for `kazi propose`

## Status
Accepted

## Date
2026-06-23

## Context

`kazi propose "<idea>"` turns a prose idea into a draft `Kazi.Goal` whose
acceptance predicates make "done" machine-checkable (ADR-0002), persisted as a
`proposed` artifact the operator reviews and approves before it runs (the
Authoring write path, ADR-0011). Today `Kazi.Authoring.propose/2` is a
**one-shot**: `validate_idea -> drive_harness` (a single `build_prompt/1` +
`harness.run/3`) `-> parse_proposal -> persist`. A one-line idea is therefore
drafted into *guessed* predicates: nothing interrogates the under-specification
before the draft is written.

The operator already authors plans and ADRs interactively with the Claude Code
CLI, which asks sharp clarifying questions before committing to a design. For
`propose` to be a real upgrade over that workflow -- not a downgrade -- it must
interrogate at least as well, and then end somewhere prose cannot: an
**executable, machine-checkable goal kazi drives to objective truth**.

Three sub-decisions were evaluated explicitly with the operator:

1. **Where the clarifying-question intelligence lives.** Options: harness-only
   (the agent decides every question; maximally flexible, non-deterministic, hard
   to unit-test), kazi-only deterministic heuristics (pure Elixir gap rules; fully
   testable and fast but rigid and blind to novel ideas), or a hybrid.
2. **The interaction surface for the first slice.** CLI TTY only, or also the
   Telegram bridge (T3.7a) / a dashboard panel.
3. **How the rationale ("why these predicates / what is out of scope") is
   emitted.** Inline on the goal, a written ADR-lite doc per proposal, or both.

## Decision

Add a **clarify phase between the idea and the draft**, reusing the existing
injectable harness seam (`Kazi.Authoring`'s `:harness` opt -> `run/3`, the same
seam the convergence loop uses) so every new harness interaction is stubbable and
no real `claude`/network is touched in tests. The phase produces a small
structured set of 2-4 multiple-choice questions (each with a free-text escape),
renders them in the terminal, folds the answers deterministically into the draft
prompt, then runs the existing draft + persist path. The review loop reuses
`edit/3` to converge the goal before it runs.

1. **Question generation is HYBRID.** The harness drafts candidate clarifying
   questions from the idea, AND kazi enforces a **deterministic floor** of
   gap-checks in pure Elixir: it always asks for the live-verification target and
   the scope boundary when the draft lacks them, and keys further gaps off the
   known provider set (`test_runner`, `http_probe`, `prod_log`, `browser`) and
   missing predicate config. The floor is pure and unit-tested with a stub
   harness; the harness-drafted questions layer on the same seam. The floor's
   bias toward a live-verification predicate (a `prod_log`/`http_probe` check
   against a deployed target) is deliberate -- it is kazi's core differentiator
   over a prose plan that stops at "tests pass locally".

2. **The interaction surface is the CLI TTY, first slice only.** Interactive
   multiple-choice prompts in the terminal. A non-interactive context (no TTY, a
   pipe, or `--yes`) skips clarification and drafts best-effort, so scripted
   authoring keeps working; a `--strict` flag fails loudly when the idea is too
   underspecified to draft. Telegram and dashboard surfaces are explicitly OUT OF
   SCOPE here and recorded as deferred follow-ups -- the clarify phase is built as
   a surface-agnostic core (questions in, answers out) so those surfaces can drive
   the same core later.

3. **Rationale is INLINE by default, with an optional `--adr` flag.** `propose`
   always stores a concise rationale (why these predicates, what is deliberately
   out of scope) on the draft goal's metadata and prints it at review time. Passing
   `--adr` additionally writes an ADR-lite rationale document under `docs/adr/`.
   Lightweight by default; a paper trail on demand.

This extends, and does not relitigate, ADR-0011 (the propose -> review -> approve
write path and its state machine) and ADR-0002 (predicates make "done"
machine-checkable). The clarify phase sits strictly *before* the existing
`proposed` state; the approval state machine is unchanged.

## Consequences

- **Sharper goals, fewer bad drafts.** The questions exist specifically to make
  acceptance predicates precise, so the first draft is closer to what the operator
  meant -- and crucially pushes for a live-verification predicate that prose
  authoring tends to omit.
- **Determinism is preserved where it matters.** The gap-detection floor, the
  question-schema parsing, and the answer-folding are pure functions, unit-tested
  with a stub harness. Only the harness-drafted *candidate* questions are
  non-deterministic, and they are additive over a tested floor.
- **The injectable-harness seam is reused, not widened.** No new external
  dependency; the clarify phase is another `run/3` call behind the same `:harness`
  opt, so tests inject a stub exactly as the draft path already does.
- **Scope is bounded to the CLI.** Telegram/dashboard authoring through the
  clarify loop is deferred. The core is built surface-agnostic so that deferral is
  cheap to lift later, but this slice ships only the terminal experience.
- **A second non-interactive path to keep honest.** `--yes`/no-TTY must draft
  without questions and `--strict` must fail loudly; both need explicit tests so a
  piped `propose` never blocks waiting on stdin.
- **Optional ADR clutter.** `--adr` writing a doc per proposal could proliferate
  thin ADRs; it is opt-in precisely so the default stays clean.

## Alternatives rejected

- **Harness-only question generation.** Closest to the raw Claude-CLI feel but
  non-deterministic and hard to unit-test; rejected in favor of the hybrid, which
  keeps a tested floor while still layering agent-drafted questions on top.
- **kazi-only deterministic heuristics.** Fully testable and fast, but rigid and
  blind to novel ideas the fixed rules do not anticipate; rejected as the sole
  mechanism, kept as the floor.
- **Always writing an ADR-lite doc per proposal.** Matches an ADR-per-decision
  habit but clutters `docs/adr/` for every small idea; made opt-in via `--adr`.
- **Building Telegram/dashboard clarify in the same slice.** Larger surface area
  (async question/answer over chat, a LiveView panel) for no extra core value;
  deferred behind the surface-agnostic core.

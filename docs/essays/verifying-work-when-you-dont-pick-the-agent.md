---
title: "Verifying work when you don't pick the agent"
covers: [harness-agnostic]
reviewed: 2026-07-19
status: published
---

## The moment

The question shows up in a dozen phrasings, but it's always the same shape:
*"How do I verify an AI coding agent's 'done' claim, given that my team uses
Claude Code this month and something else next quarter?"* You cannot answer
it by picking a verification approach that only works inside one agent's
own loop — the answer has to sit above whichever agent is actually running.

**Short answer: put the verification layer outside the agent, not inside
it, so it survives a harness swap.** A goal declared as machine-checkable
predicates, checked by something the agent does not control, works the same
whether the agent driving it is Claude Code, Codex, opencode, or whatever
ships next year.

## What actually goes wrong

Verification schemes that live *inside* one agent's own conventions —
its native "done" heuristics, its built-in test-runner integration, a
prompt template tuned to one model's quirks — are, definitionally, tied to
that agent. Switch harnesses (a new hire prefers a different CLI, a
procurement decision changes the default, a better model ships on a
different platform) and the verification discipline has to be rebuilt from
scratch on the new tool. Worse: two agents on the same team, each grading
its own work by its own internal notion of "done," produce two different
bars for the same codebase.

The deeper issue is coupling the *judge* to the *worker*. If the same
system that writes the code also owns the definition of done, that
coupling doesn't go away just because you changed which vendor's model is
doing the writing.

## How kazi closes it

kazi's acceptance predicates are evaluated by kazi itself, not by whichever
harness is driving the loop (ADR-0002). The harness is a pluggable profile
(ADR-0016) that kazi drives to edit code and re-run the checks; today that
profile list is Claude Code, Codex, opencode, Antigravity, Claw, and Gemini
CLI. A new harness that meets the onboarding conformance bar (ADR-0022)
slots in without the goal-file, the predicates, or the evidence format
changing at all.

Concretely: `kazi apply my-goal.toml --harness claude` and `kazi apply
my-goal.toml --harness opencode` converge the *same goal* against the *same
predicate vector* — only the worker changes. The goal-file is portable
across your team's harness choices; the verification bar is not
renegotiated per agent.

## The evidence

`kazi help --json` lists `--harness` as a first-class flag on `apply`, not
a per-harness fork of the tool. The harness-conformance discipline
(ADR-0022) is what lets a new profile be added without touching the
predicate-evaluation code path — the same dogfood fixtures that converge
under `--harness claude` are the ones a new harness profile is validated
against before it ships (see `docs/dogfood-methodology.md` for the
reproducible run format).

## What this does not solve

Harness-agnosticism doesn't make every harness equally capable — a weaker
model under a given harness will still take more iterations or land
`stuck` more often on a hard goal; kazi reports that honestly rather than
smoothing it over. And a harness has to reach the ADR-0022 conformance bar
before it's trustworthy inside the loop — "any CLI agent" means any agent
that meets the bar, not literally anything with a shell.

## Anchors

- ADR-0002 — goals as predicates
- ADR-0016 — generic harness profiles
- ADR-0022 — harness onboarding conformance

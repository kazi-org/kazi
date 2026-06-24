# ADR 0030: Content-marketing and agent-native positioning strategy

## Status
Accepted

## Date
2026-06-24

## Builds on
ADR-0025 (docs lead with the agent-driven on-ramp). ADR-0025 fixed the ORDER
(agent on-ramp first, vanilla demoted). This ADR fixes the CONTENT STRATEGY and
MESSAGING -- the words, the hero asset, the social proof, and the growth engine --
grounded in deep research of how the fastest-growing OSS AI dev tools won stars.

## Context

kazi's shipped paradigm is now: a developer CHATS with their coding agent (Claude
Code), and the AGENT drives kazi (via the `kazi` Claude Code skill / `kazi mcp` /
the `--json` CLI), which drives a harness in a reconcile loop until the goal is
OBJECTIVELY done. The human does not operate kazi directly -- that is the legacy
human -> kazi route, now the power-user/reference path. But the README and website
still LEAD with human -> kazi ("You tell it the outcome... kazi drives a coding
agent"), so the first screen sells the wrong paradigm.

Deep research (docs/devlog.md 2026-06-24, two sourced reports across ~15 fast-
growing tools + the agent-native/MCP tier + HN launch data) produced a clear
playbook. The closest analogs to kazi -- a tool the user does NOT directly operate
-- are Serena ("The IDE for Your Coding Agent" / "Give your agent the tools it has
been asking for"), Context7 ("Up-to-date docs for any prompt"; invocation IS the
marketing: append "use context7"), and Astral's Ruff/uv (a benchmark chart as the
hero, a falsifiable "10-100x" number). Key sourced findings:

- A category-defining one-liner in the HUMAN's noun, never the protocol's, in line 1.
- Lead with a VISUAL that proves the core claim; for an agent-driven tool that is a
  transcript/recording of the agent USING the tool to reach an outcome.
- Agent-facing tools pitch "give your agent X" (benefit to the human, delivered
  through the agent), lead with the agent's CURRENT PAIN then show it fixed
  (Context7's before/after), and make the invocation a memorable phrase.
- A falsifiable, theatrical proof number + a living public leaderboard is the most
  durable growth engine (Aider's leaderboard, Astral's benchmark).
- Two-layer social proof: clean README, proof-heavy site; "works with the agents
  you already use"; Serena's standout: testimonials authored BY the agents.
- HN is the highest-leverage launch channel; title = "<Name> - <plain capability>".
- Top risks: "done" is harder to make falsifiable than "fast" (#1); a brand-new
  category ("reconciliation controller") incurs an education tax -- a BORROWED frame
  ("CI for coding agents" / "a linter for 'done'") is graspable in one line.

## Decision

Adopt a research-grounded content strategy for the README, website, and docs, with
these decisions:

1. **Lead every surface with the agent-driven paradigm and a human-noun tagline.**
   The first line names what the human GETS, through their agent -- not
   "reconciliation controller." Pair the precise category with a BORROWED frame for
   graspability (e.g. "CI for coding agents" / "makes your coding agent actually
   finish"). The exact wording is chosen in execution (E25/T25.1) and A/B-able, but
   it MUST: name the agent kazi drives, lead with the outcome, avoid jargon in line 1.
   Canonical strings (ADR-0018) are updated in lockstep with the site.

2. **The hero asset is a transcript/asciinema of the loop** -- Claude Code -> kazi ->
   harness with predicates flipping false -> true, ending at "goal objectively true."
   This is kazi's benchmark-chart equivalent and the single highest-leverage asset;
   it doubles as the README image, the tweet, and the HN thumbnail. (Prefer
   asciinema/SVG over GIF for crispness; a static styled fallback is acceptable until
   a real cast exists, honestly labelled.)

3. **A "without kazi / with kazi" before-after block** (Context7's most-copied
   device): without -- agents declare "done" when it isn't, drift, stop early, blow
   budget silently; with -- driven in a loop until predicates are objectively true,
   stuck, or over budget.

4. **Agent-native social proof.** A "works with the agent you already use" row
   (Claude Code, Codex, opencode) and -- uniquely on-brand -- an AGENT-VOICED
   testimonial (a coding agent describing what kazi lets it do). Two-layer: README
   stays lean; the site carries the heavier proof.

5. **A memorable invocation.** Document the exact phrase a human types at their agent
   to invoke kazi (Context7's "use context7" pattern), so adoption is one phrase, not
   a behavior change.

6. **Commit to ONE recurring growth engine: a dogfood "done" gallery/leaderboard** --
   "goals a prose pipeline left subtly broken that kazi converged," built from the
   dogfood fixtures (T0.12/T1.8) + the live production probe. This is kazi's
   Aider-leaderboard: each new fixture is a new earned-media post, and it directly
   attacks risk #1 by turning "objective done" into reproducible numbers.

7. **A launch kit** (Show HN title + post, X thread, README OG card) framed against
   the live pain ("agents that claim done but aren't"), timed to a model release or
   an "agents hallucinate done" moment. Honest: no unshipped command shown as
   working; promised work labelled "coming" (ADR-0025).

Vanilla human -> kazi stays as the reference tier (ADR-0025), never the lead.

## Consequences

- The first screen finally sells the shipped paradigm (agent drives kazi), matching
  how the fastest-growing analogs (Serena/Context7) position invisible tools.
- kazi gets a durable growth engine (the dogfood leaderboard) instead of one-shot
  launch copy -- the pattern most correlated with sustained star growth.
- The hero transcript is a build dependency (needs a real, recordable end-to-end
  run); until it exists, surfaces use an honest static fallback.
- Messaging is now a maintained surface with a strategy of record; future copy edits
  must not regress to the human-operator framing or to jargon-first taglines.
- Borrowing a frame ("CI for agents") risks under-selling the novel category; the
  precise category line sits directly beneath the borrowed hook to keep both.
- The "done" number must hold up (risk #1): the leaderboard methodology must be
  honest and reproducible or it backfires (the Ruff lesson: the number held, which
  is why it worked).

## Alternatives rejected

- **Keep leading with human -> kazi.** Sells the legacy route; the shipped, lower-
  friction paradigm is agent-driven. Rejected (this ADR's reason for existing).
- **Lead with the precise new category ("reconciliation controller for software
  goals").** Accurate but incurs the category-education tax; research shows breakouts
  used borrowed frames. Keep the precise line as the second beat, not the hook.
- **Architecture-diagram hero (the controller's internals).** Agent-facing winners
  lead with the agent USING the tool, not internals. Rejected.
- **Scatter launch effort across HN + Reddit + Product Hunt equally.** Research found
  HN the only channel with falsifiable leverage data; Reddit/PH unproven. Lead with
  HN; treat the others as secondary.
- **Chase the star count directly (buy or game it).** Stars are gameable and ~5x
  weaker than real ones; instrument downloads/retention instead.

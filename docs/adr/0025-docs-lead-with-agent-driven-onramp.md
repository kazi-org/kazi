# ADR 0025: Documentation and website lead with the agent-driven on-ramp

## Status
Accepted

## Date
2026-06-24

## Context

kazi's README, website, and docs currently lead with VANILLA kazi: install ->
`mix kazi.run goal.toml` / `kazi propose` at a terminal. But the lowest-friction,
most-likely adoption path is the INVERSE -- a developer already living in Claude
Code (often remotely: phone -> a Mac in the office) tells their agent to use kazi,
and Claude Code drives kazi, which drives a coding harness as the implementer
(claude -> kazi -> claude/cheap-harness; ADR-0023's 3-layer stack). People reach
for kazi from INSIDE the agent that already works for them; they do not start by
learning a new CLI. Leading with vanilla kazi asks a newcomer to abandon the
ergonomic path (their agent) and adopt a less ergonomic one (a bare controller
CLI) -- a regression in their experience and a friction wall for adoption.

The agent-drivable surface that makes the easy path real is now SHIPPED: every
command has `--json` + a versioned result contract, `propose` has a caller-drafts
mode, and `kazi help --json` / `schema` self-describe (E15 + T16.1, ADR-0023 /
ADR-0024). What is NOT yet shipped is the one-command on-ramp -- `kazi
install-skill` (the Claude Code skill) and `kazi mcp` (T16.2 / T16.5) -- which is
what turns "drive kazi from your agent" from a copy-paste recipe into "it just
knows." Adoption speed (GitHub stars, the claw-code-style curve the operator is
targeting) hinges on the first screen of every surface showing that easy path.

This decision sets the DOCUMENTATION INFORMATION ARCHITECTURE. It does not change
the product (ADR-0001: kazi is still the outer loop, never a harness) -- only what
the surfaces lead with. It builds on ADR-0023/0024 (agent-drivable + self-teaching)
by fixing the order in which the surfaces present those capabilities.

## Decision

1. **Every primary surface leads with the agent-driven on-ramp.** README hero, the
   website hero, and the docs entry all open with: keep using Claude Code (the
   agent you already use, from anywhere) and add kazi so its work is OBJECTIVELY
   done and the grind can run CHEAP. The first code block is the on-ramp, not
   `kazi run goal.toml`.

2. **The headline on-ramp is `brew install` + `kazi install-skill`, then "tell
   Claude Code to use kazi."** The MCP path (`kazi mcp`) is the lowest-friction
   tier for MCP-native clients. **Promising planned work is OK** (operator decision
   2026-06-24): the docs MAY lead with this one-command on-ramp BEFORE `install-skill`
   / `mcp` ship, provided it is clearly MARKED as the intended/coming experience
   (e.g. a "coming in vNext" tag) and the works-today recipe (`propose --json` ->
   `approve` -> `run --harness <cheap> --json`, on the shipped JSON CLI) is shown
   alongside so a reader can act now. The guard is honesty-by-LABELLING, not
   omission: an unshipped command is never presented as already working, but the
   roadmap on-ramp may lead. The droppable `AGENTS.md` (T16.3) is the harness-neutral
   companion. The rewrite is therefore NOT gated on T16.2/T16.5; it flips "coming"
   to "available" as they land.

3. **Vanilla kazi becomes the REFERENCE tier, below the fold.** `kazi run` /
   `propose` at a terminal, harness config, build-from-source, and the goal-file
   schema remain in full -- they are the power-user / CI path -- but they follow
   the agent on-ramp, they do not precede it.

4. **Messaging is workflow-centric, not tool-centric, and HONEST about cost.** Lead
   with the user's outcome ("your agent's work, provably done; the grind, cheap"),
   carry the concrete remote vignette (drive from your phone; kazi rides along on
   the same machine), and state the cost story truthfully per the benchmark
   (docs/devlog.md 2026-06-24): NO token overhead vs vanilla at the same model;
   "cheaper" comes from model-tiering and is gated by local-model speed -- never
   claim an unearned number.

5. **Canonical strings stay locked; coherence holds.** The canonical strings
   (install command, positioning one-liner, Kubernetes framing) and the README<->
   site drift-check (T9.9) are preserved; README and site are updated in lockstep.
   No invented features -- every command shown is real at publish time.

## Consequences

- The first screen sells the easy path early adopters will actually use, which is
  the highest-leverage lever for star/adoption growth.
- The rewrite is on the adoption critical path and is UNBLOCKED now: it may lead
  with the promised one-command on-ramp (clearly marked "coming") with the
  works-today recipe (T17.4) alongside, and flip the tag to "available" as T16.2
  (skill) / T16.3 (AGENTS.md) / T16.5 (mcp) land. Honesty is preserved by
  LABELLING, not by withholding the roadmap on-ramp.
- Vanilla-kazi users lose nothing: the reference tier is intact, just demoted.
- A standing editorial invariant: future doc edits must not regress the surfaces
  to tool-centric framing; the agent on-ramp leads. The coherence check guards the
  canonical strings; this ADR guards the lead order.

## Alternatives rejected

- **Keep leading with vanilla kazi.** It asks newcomers to leave the ergonomic
  agent path they already have; it is the current friction wall this ADR removes.
- **Withhold the one-command on-ramp until it ships.** Rejected (operator decision
  2026-06-24): promising the planned on-ramp -- clearly marked "coming," with the
  works-today recipe alongside -- is acceptable and accelerates adoption; honesty is
  preserved by labelling, not by omission. Presenting an unshipped command as
  already-working is still forbidden.
- **Drop vanilla kazi from the docs.** It is the real power-user/CI surface and the
  honest substrate the agent path drives; demote, do not delete.

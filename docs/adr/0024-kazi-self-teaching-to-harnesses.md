# ADR 0024: kazi is self-teaching to harnesses (skill + MCP + machine-readable help)

## Status
Accepted

## Date
2026-06-23

## Context

ADR-0023 makes kazi agent-DRIVABLE (a `--json` contract, a versioned result
schema). But drivable is not the same as DISCOVERABLE: an orchestrating harness
(Claude Code today -- the dominant tool for early adopters) must KNOW the commands,
the `propose -> approve -> run` recipe, the caller-drafts mode, and the result
schema before it can drive kazi. Adoption hinges on "I installed kazi and my agent
already knows how to use it." kazi should be SELF-TEACHING: it describes itself in
machine-readable form and ships the integration glue for the dominant harness, so
the on-ramp is `brew install` -> the agent can drive it.

## Decision

1. **Ship a Claude Code SKILL, opt-in.** `kazi install-skill` writes
   `~/.claude/skills/kazi/SKILL.md` teaching the orchestrator recipe: caller-drafts
   `kazi propose --json` -> review/`approve` -> `run --harness <cheap> --json
   [--stream]` -> parse the result -> branch on `next_action`, plus the two-tier
   economics (strong model authors predicates, cheap/local model runs the loop,
   predicates keep it honest). `brew install` PRINTS a hint to run it; it does NOT
   auto-write to the user's `~/.claude` (consent-first).

2. **kazi self-describes in machine-readable form.** `kazi help --json` emits the
   command/flag surface; `kazi schema [<command>]` emits the versioned result
   schemas (ADR-0023). So ANY agent -- not just Claude -- can introspect kazi at
   runtime without external docs.

3. **A generic `AGENTS.md` teachability doc** ships in the repo and is droppable
   into a target repo, for harnesses that read repo conventions (Cursor rules,
   etc.). Same recipe, harness-neutral.

4. **A `kazi mcp` server is the self-describing tool surface** -- promoted from
   "deferred" (ADR-0023) to a first-class teachability path, built AFTER the JSON
   CLI it wraps. MCP tool descriptions + schemas ARE the teaching; a Claude Code (or
   any MCP) user connects and drives kazi natively, no shelling/parsing.

Tiered by harness: Claude Code -> the SKILL (most ergonomic for the operator's
setup); MCP-speaking harnesses -> `kazi mcp` (self-documenting tools); any agent ->
`kazi help --json` / `kazi schema` + `AGENTS.md`.

## Consequences

- **A strong adoption on-ramp:** `brew install kazi-org/tap/kazi && kazi
  install-skill` -> Claude Code can drive kazi out of the box. This is the viral
  hook -- it works with the tool early adopters already use.
- kazi is usable by agents we did not anticipate, because it self-describes
  (`help --json` / `schema`) rather than relying on a human reading prose.
- Opt-in + a printed hint respects the user's environment -- no surprise writes to
  `~/.claude` (and it honors the operator's own "global skills, don't auto-create"
  discipline).
- **Drift risk:** the SKILL / `AGENTS.md` can fall out of sync with the real CLI; a
  coherence test must assert they reference only real commands/flags (the same
  guard pattern as the README<->site check, T9.9), and `kazi help --json` is
  generated from the actual command table, not hand-maintained.
- The MCP server is additional surface to maintain; it is sequenced after the JSON
  CLI so it consumes a proven contract.

## Alternatives rejected

- **Auto-install the skill on `brew install`.** Intrusive -- writes to the user's
  Claude config without consent. Opt-in + a printed hint is the courteous default.
- **Rely on README/docs alone.** Agents do not reliably read prose docs; a
  structured skill + machine-readable `help --json`/`schema` is far more reliable
  and is itself parseable.
- **MCP-only.** Not universal (non-MCP agents are left out); the skill + `help
  --json` + `AGENTS.md` cover them, and MCP is the richest tier on top.

# ADR 0032: Rename the CLI verbs -- run -> apply, propose -> plan (unify human/skill/CLI)

## Status
Accepted

## Supersedes (in part)
ADR-0031 -- specifically its decision to KEEP the CLI verbs `run`/`propose` and only
name the SKILL sub-skills `apply`/`plan` (the "skill verb != CLI verb" map). This ADR
unifies them: the CLI verbs themselves become `apply`/`plan`. Updates the command
names referenced in ADR-0023 (`run --json` result contract, `propose --json`
caller-drafts) and ADR-0024 (the self-teaching skill recipe).

## Date
2026-06-24

## Context

kazi's user-facing verbs are inconsistent across layers. The CLI ships `kazi run`
(converge a goal) and `kazi propose` (author predicates); the operator's workflow
vocabulary and the planned skill router (ADR-0031) use `apply` (execute the plan)
and `plan` (author intent). ADR-0031 papered over the gap with a skill-verb ->
CLI-verb map (`apply` -> `run`, `plan` -> `propose`), but the operator wants the
verbs CONSISTENT end to end so there is one name per concept: the thing you type at
the agent, the skill, and the CLI all read the same.

`run`/`propose` are referenced widely: `lib/kazi/cli.ex` (command parsing), the
`mix kazi.run` task, the `--json` result/draft schemas (`docs/schemas`, a
compatibility surface, ADR-0023 R-E15-1), the shipped `kazi install-skill`
SKILL.md + `AGENTS.md` (ADR-0024), the `kazi mcp` tools, README/site/concept/docs,
and the test/conformance suites. A rename touches all of them, and the agent-drivable
JSON contract + the already-shipped skill/MCP are surfaces real callers may pin.

## Decision

1. **Rename the primary CLI verbs:** `kazi run` -> `kazi apply`, `kazi propose` ->
   `kazi plan`. These become the canonical commands everywhere (help, schemas,
   skill, docs). The mental model is now uniform: `kazi plan` authors intent,
   `kazi apply` converges it -- matching `/plan` and `/apply`.

2. **Keep `run`/`propose` as DEPRECATED ALIASES** that still dispatch to the same
   code and print a one-line deprecation hint to stderr (never into `--json` stdout).
   Rationale: the JSON contract + the shipped skill/MCP/agent recipes are
   compatibility surfaces in the wild; aliases avoid breaking existing callers
   mid-flight. The aliases are scheduled for removal in a later minor (a written
   deprecation window, not forever).

3. **`mix kazi.run` -> `mix kazi.apply`**, with `mix kazi.run` kept as a deprecated
   alias task, for the same reason.

4. **Bump the result-contract `schema_version`** and key the schemas by the new
   command names (`apply`, `plan`); document the old names as deprecated aliases so
   an orchestrator pinning `schema_version` sees the change explicitly (ADR-0023).

5. **Update every surface in lockstep:** `kazi help --json` (generated -- lists
   `apply`/`plan` as primary, `run`/`propose` as deprecated aliases), `kazi schema`,
   the `install-skill` SKILL.md + `AGENTS.md` (the E26 router verbs now equal the CLI
   verbs 1:1 -- T26.1's verb-map becomes an identity), the `kazi mcp` tool names,
   README/site/concept/docs, and the tests/coherence guards (T9.9, T16.4) +
   self-conformance (T15.7).

6. **E26 simplifies.** With the CLI renamed, the router's sub-skill verbs match the
   CLI verbs exactly; ADR-0031's verb-map rationale is retired (kept only as the
   alias note for `run`/`propose`).

## Consequences

- One name per concept across the agent prompt, the skill, and the CLI -- the
  consistency the operator asked for; lowers cognitive load and doc drift.
- Back-compat preserved via aliases, so the shipped skill/MCP and any agent recipes
  keep working through the deprecation window; nothing breaks the day of the rename.
- A real blast radius: cli.ex, the mix task, the schemas (+ `schema_version` bump),
  the skill/AGENTS.md/MCP, README/site/docs, and tests all change -- this is the kind
  of broad, mechanical, well-specified work the apply pool can execute autonomously
  (and it refills the pool's queue, which was starved of pure-code tasks).
- The `schema_version` bump is a breaking change to the result contract's command
  key; orchestrators pinning the schema must update -- documented, not silent.
- Two names exist during the deprecation window (slightly more surface to test); the
  coherence guards + the alias tests bound the risk.

## Alternatives rejected

- **Keep ADR-0031's split (CLI `run`/`propose`, skill `apply`/`plan`).** The operator
  explicitly wants end-to-end verb consistency; the split keeps two names per concept.
- **Hard rename with NO aliases.** Pre-1.0 makes this tempting, but the
  agent-drivable JSON contract + the already-shipped skill/MCP are surfaces real
  callers pin; a clean alias + deprecation window is the courteous, low-risk path.
- **Rename only one verb.** Half-consistent; do both or neither.
- **Rename without bumping `schema_version`.** Silent change to a pinned
  compatibility surface; rejected (ADR-0023 mandates versioning the contract).

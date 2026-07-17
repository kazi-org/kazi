# ADR-0074: install-skill ships a self-contained multi-file skill with a LOCAL.md extension point

## Status

Accepted

## Date

2026-07-16

## Context

`kazi install-skill` (ADR-0024) writes the Claude Code skill that teaches an
orchestrating agent how to drive kazi. Two problems accumulated:

1. **The shipped skill referenced skills kazi does not ship.** The router told
   agents to "fall back to the generic `/plan` + `/apply` skills" and described
   `/plan`/`/tidy` as the layers around kazi. Those are one operator's private
   skills; a fresh kazi user has none of them, so the shipped skill pointed at
   dead ends. `AGENTS.md` carried the same references.
2. **Operators had no safe place for site wiring.** Any local edit to the
   generated SKILL.md (routing conventions, model policy, which local
   orchestration skill owns plan-driven work) was silently clobbered by the
   next `install-skill` run -- the drift class behind issue #956, where a
   tiering fix lived only in a local dotfile.

Separately, the single SKILL.md had grown past 500 lines; the authoring-quality
guidance (dense predicate briefs, capability-vs-guard, red-at-t0 -- #924/#1128)
and the operational recipes (escalation ladder, gate variant, session bus)
deserve progressive disclosure rather than one monolithic prompt.

## Decision

1. **The skill is SELF-CONTAINED.** No rendered document may reference an
   operator-local skill (`/plan`, `/apply`, `/claim`, `/tidy`, `/loop`,
   `/qualify`, ...). The non-kazi-repo fallback is "your own
   planning/execution workflow". A test enforces this over every rendered
   document, and `AGENTS.md` is scrubbed to match.
2. **`install-skill` writes three documents**: `SKILL.md` (the router),
   `AUTHORING.md` (predicate authoring quality: task brief, one requirement
   per predicate, capability-vs-guard + red-at-t0, provider inference), and
   `RECIPES.md` (escalation ladder, streaming/parallel/standing/explain, the
   check-only gate variant, status/dashboard, adopt, the session bus,
   schema_version pinning). The router points to the other two at their point
   of use. All three are exposed as functions (`skill_md/0`, `authoring_md/0`,
   `recipes_md/0`) and all three are held to the T16.4 coherence guard.
3. **`LOCAL.md` is the operator-owned extension point.** `install-skill` NEVER
   writes or overwrites `<skill-dir>/LOCAL.md`. The generated SKILL.md
   instructs the agent to read `LOCAL.md` FIRST when present -- that is where
   site-specific routing (e.g. "plan-driven engineering goes through my local
   orchestration skill") lives, and it survives every re-install.

## Consequences

- A fresh `kazi install-skill` gives any user a complete, working skill with
  zero external dependencies -- authoring quality and operational recipes
  included.
- Operators integrate kazi with private workflows via `LOCAL.md` instead of
  forking the generated skill; re-installs stop destroying local wiring
  (closes the #956 drift class at the mechanism level).
- The coherence guard now scans three rendered documents, so recipe/reference
  content is held to the same no-drift bar as the router.
- Re-installs leave exactly the three managed files plus whatever `LOCAL.md`
  the operator wrote; tests pin the set.
- Anyone who previously depended on the shipped skill naming `/plan`/`/apply`
  must supply their own routing in `LOCAL.md` -- which is the point.

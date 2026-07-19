# ADR 0052: Self-teaching artifacts must not assume the operator's personal skill library; retire the non-functional Graphify retrieval backend

## Status
Accepted

## Date
2026-07-01

## Context

An audit (prompted by the concern "assume kazi users do not have any of my
Claude Code skills") found that kazi's own shipped self-teaching artifacts
violate that assumption in two confirmed spots, plus one unrelated dead
integration surfaced by the same sweep:

1. **`AGENTS.md`** (repo root -- a public, git-committed file ADR-0024
   mandates shipping as kazi's harness-neutral teaching doc, meant to be read
   by ANY agent, not only Claude Code) states: *"The strategy layer above kazi
   is `/plan` (ADRs, use cases, the WBS, the intent)... `/tidy` stays
   orthogonal hygiene."*
2. **`lib/kazi/teach/install_skill.ex`** -- the `SKILL.md` `kazi install-skill`
   writes to EVERY kazi user's `~/.claude/skills/kazi/` -- goes further:
   *"Fall back to the generic `/plan` + `/apply` skills,"* *"`/loop` and
   `/qualify` remain available as GENERAL skills for non-code work."*

Both assume `/plan`, `/tidy`, `/loop`, `/qualify` (the operator's personal
global skills) are a universal Claude Code baseline. They are not shipped by
kazi, not a Claude Code convention, and most kazi users will never have them.
The root cause is not a stray implementation slip: ADR-0024, ADR-0026, and
ADR-0031 are written explicitly from the operator's own vantage point --
*"the operator's `/apply --pool`,"* *"matching their existing muscle
memory,"* *"the operator's workflow"* -- and that framing was carried
uncritically into public, shipped artifacts. This is the same "audience of
one" failure ADR-0015 already named and rejected for the bespoke
`capabilities.json` importer, recurring in a different location.

The same sweep found **`Kazi.Retrieval.Graphify`**
(T4.9b, ADR-0012): it shells out to
`System.cmd("graphify", ["similarity-search", "--format", "json", ...])`,
treating `/graphify` as an installable CLI binary. Direct inspection of the
real `/graphify` skill (`~/.claude/skills/graphify/`) confirms it has no such
binary -- every subcommand in its `SUBCOMMANDS.md` is an inline
`$PYTHON -c "..."` snippet the Claude Code AGENT executes as part of following
the skill's Markdown instructions, not a standalone executable. There is
nothing on any PATH named `graphify` to shell out to, for any user, including
the operator. A follow-up proposal to have kazi's OWN installer "also install
graphify" is not actionable today: there is no installable `graphify` CLI
artifact anywhere to fetch. Building one would be a nontrivial, SEPARATE
undertaking in the graphify skill's own project (outside kazi's repo and
control) -- not a decision this ADR is positioned to make, and not something
`kazi install-skill` can conjure into existence.

## Decision

1. **Rewrite the two self-teaching artifacts to describe the CONTRACT, never
   a specific external skill name.** `AGENTS.md` and
   `lib/kazi/teach/install_skill.ex`'s generated `SKILL.md` are corrected so
   that wherever they currently say "fall back to `/plan`/`/apply`" or
   "`/tidy`/`/loop`/`/qualify` remain available," they instead say something
   in the shape of: *"If an upstream planning/strategy process already
   produced acceptance criteria (a WBS, a spec, an ADR), derive `kazi plan`'s
   predicates from it -- kazi has no opinion on how that upstream artifact was
   produced. A separate hygiene/cleanup pass, if you run one, is orthogonal to
   convergence and does not gate it."* No bare `/word` token naming an
   unshipped skill remains in either file.
2. **Extend the existing SKILL/AGENTS.md coherence guard** (`T16.4`,
   `test/kazi/teach_coherence_test.exs`) to also fail if either artifact
   contains a `/<word>` token that is not a documented `kazi` CLI verb (from
   `kazi help --json`'s command list) -- a standing regression guard against
   this exact class of mistake recurring.
3. **Retire `Kazi.Retrieval.Graphify`** -- delete the module and its tests.
   `Kazi.Retrieval`'s pluggable behaviour + `NoOp` default (ADR-0012) is
   untouched and was always the correct architecture; the mistake was
   hardcoding one specific, non-existent tool as "the real backend" rather
   than leaving real backends to whoever owns a genuine CLI/API for one.
   Document in `Kazi.Retrieval`'s moduledoc that a real adapter can be added
   later against ANY tool that exposes an actual, installable command-line or
   HTTP interface for embedding + similarity search -- kazi bundles none by
   default today, and does not require it to be named "graphify."
4. **Do not attempt to make kazi's installer "install graphify."** There is
   no installable artifact to fetch. If a genuine, standalone graphify CLI is
   ever built (a separate, out-of-kazi-repo effort with its own documented
   interface), a real adapter can be added the same way `code-review-graph`
   (a genuine external binary + MCP server) is already integrated --
   presence-checked, with a working fallback when absent (ADR-0010). That is
   a future decision gated on that CLI existing, not this one.
5. **ADR-0024/0026/0031 remain Accepted** -- their core decisions (the SKILL
   router shape, the pool-interop model) are sound and unchanged. This ADR
   corrects their operator-centric FRAMING, not their substance. Future ADRs
   should write "an upstream planning process," never "the operator's
   `/plan`."

## Consequences

- kazi's shipped teaching artifacts stop giving broken guidance to the vast
  majority of real users, who do not have the operator's personal skill
  library.
- Removes a permanently non-functional code path (`Kazi.Retrieval.Graphify`)
  with zero loss of working capability -- it never worked, for anyone.
- The extended coherence guard catches a recurrence of this specific mistake
  automatically, the same way T16.4 already catches CLI-surface drift.
- Retrieval stays exactly as extensible as before for anyone who wants to
  plug in a REAL backend (`config :kazi, :retriever, {MyModule, opts}`) --
  only the fake "real" default implementation is removed, not the seam.
- Rework required: `AGENTS.md`, `install_skill.ex`, and their respective
  tests all need edits in the same change (ADR-0034, docs land with code).

## Alternatives rejected

- **Make kazi's installer install graphify.** Rejected: no installable
  artifact exists; would require first building an entire external CLI
  project this ADR has no standing to commission.
- **Keep the language, add a caveat ("if you have this skill").** Rejected:
  still an audience-of-one reference (ADR-0015) for the overwhelming majority
  of readers; describing the contract directly is strictly clearer.
- **Keep `Kazi.Retrieval.Graphify` as a documented "install graphify
  yourself" prerequisite.** Rejected: there is nothing to install; the
  instruction would be false.

## Related

- Corrects the framing (not the substance) of ADR-0024, ADR-0026, ADR-0031.
- Reinforces ADR-0015 (no audience-of-one surfaces).
- Touches ADR-0012 (retrieval seam) only by removing one hardcoded, dead
  adapter; the pluggable behaviour is unchanged.
- Consistent with ADR-0010's presence-checked, gracefully-degrading pattern
  for genuine external tools (`code-review-graph`), which this audit
  confirmed is already implemented correctly and needs no change.

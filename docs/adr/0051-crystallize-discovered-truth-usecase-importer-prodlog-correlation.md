# ADR 0051: Crystallize discovered truth -- an open use-case-manifest schema, a harness-driven discovery step, and prod-log predicate correlation

## Status
Accepted -- decisions 1-3 (the open `usecase-manifest.json` schema, `kazi spec
discover` as a one-shot harness command, and `UseCaseManifestImporter`)
SUPERSEDED by ADR-0054 (product-level use cases are Gherkin + tags via the
existing `GherkinImporter`, discovered by an iterative `kazi init --discover`
convergence instead). Decision 4 (prod-log predicate correlation) is RETAINED
-- see ADR-0054 decision 6.

## Date
2026-07-01

## Context

ADR-0021 already frames correctness as a two-way containment between the
**intended set I** (what should be true) and the **actual surface A** (what the
code exposes): `I \ A` is what kazi's core loop drives to done; `A \ I` is dead
or undocumented code, caught by a shipped surface-coverage meta-predicate
(T13.5). ADR-0021 imports `I` from machine specs (OpenAPI/gherkin,
deterministic) and from prose via the harness (fuzzy, human-reviewed). ADR-0050
added a third lane -- `docs/specs/*.feature` behavior specs, authored before
code, deterministically imported.

All three lanes require `I` to be **declared** before or alongside the code. A
fourth case is discovering `I` (and its violations) **empirically**, by
exploring an already-built, running system: cataloging every use case, testing
each one live, and cross-referencing wiring to find what is missing, stubbed,
or orphaned. That is a real gap.

An earlier draft of this ADR proposed closing it by importing the output of the
operator's personal Claude Code skills (`/verify`, `/qualify`) directly. That is
the wrong design: **those skills are not part of kazi, are not installed by
`brew install kazi`, and most kazi users will never have them.** An ADR that
makes a public kazi capability depend on a specific person's private skill
library produces a command that works for an audience of one -- exactly the
failure mode ADR-0015 already rejected for a different bespoke-catalog importer
("an audience of one"). This revision corrects that: `/verify`/`/qualify` are
kept only as the ORIGIN of the design idea (their manifest shape, their
wiring-gap classification, their prod-log correlation insight are all worth
copying), not as a load-bearing dependency.

kazi already has the right primitive to make this work for every user, used
today by `Kazi.Adopt.enrich/2` (ADR-0013 §4): an **opt-in, harness-driven
enrichment step**, wired through the same injectable seam as `Kazi.Authoring`
(`Kazi.HarnessAdapter.run/3`, defaulting to whatever coding harness the user
already has configured -- Claude Code, Codex, opencode, ...). `enrich/2` drives
the harness with a kazi-authored, fixed prompt to propose live predicates from
a repo's discovered endpoints; it is non-deterministic by nature, therefore
off by default, clearly separated from the deterministic path, and validates
its output is loadable before merging. This is exactly the shape needed here:
kazi does not need a specific external skill to discover use cases and wiring
gaps -- it needs one more kazi-authored prompt template driving the SAME
harness the user already runs everything else through.

kazi still should not perform live discovery inside its own deterministic core
(that would reverse ADR-0001/ADR-0009 -- kazi supplies grounded evidence and
prompt projection, not judgment). The fix is not "kazi judges the system
itself"; it is "kazi asks the harness to judge it, via a fixed, versioned
prompt, exactly like `enrich/2` already does for predicates."

## Decision

1. **An open, kazi-owned schema for a use-case manifest and a wiring-gap
   report**, documented via `kazi schema usecase-manifest` (ADR-0023) --
   independent of any specific producer. Fields: per use case, an id, domain,
   name/description, roles, interfaces, priority, and a live PASS/FAIL/UNKNOWN
   verdict; per wiring gap, kind (MISSING/STUB/ORPHAN), severity, and location.
   ANY tool that emits this shape is a valid input -- a Claude Code skill the
   user happens to have (`/verify`/`/qualify` among them), a project's own
   script, or kazi's own discovery step below.
2. **`kazi spec discover [--harness <name>] [--out <path>]`** -- a new,
   OFF-by-default-effort, explicitly-invoked command that drives the user's
   configured coding harness (the same `Kazi.HarnessAdapter.run/3` seam
   `enrich/2` and `Kazi.Authoring` already use) with a kazi-authored, fixed
   prompt: catalog use cases across the project's interfaces, test each one
   live, classify wiring gaps, and emit the schema from decision 1. This makes
   the capability available to every kazi user with any supported harness --
   no personal skill install required. Non-deterministic by nature (the
   harness does the discovering); output is validated against the schema
   before being written, same discipline as `enrich/2`.
3. **`kazi spec import --from-usecase-manifest <path> [--report <path>]
   --into <goal-ref>`** -- extends the `kazi spec import` verb (ADR-0050) with
   a mode that runs a new `Kazi.Reconcile.UseCaseManifestImporter` (a sibling of
   `GherkinImporter`/`OpenApiImporter`/`ProseImporter`) over the schema from
   decision 1, regardless of what produced it. PASS use cases become held-true
   predicates (kind by interface); wiring gaps feed the EXISTING
   surface-coverage meta-predicate (ADR-0021 decision 3, T13.5) rather than a
   second gap concept; untested use cases import as `unknown`, never a silent
   pass. Pure and hermetic over its input file -- the fuzzy discovery already
   happened in decision 2 (or externally); this step is deterministic.
4. **Prod-log correlation as a predicate-level trust check**, generalizing
   `/qualify`'s Layer 4a narrowly: extend `Kazi.Providers.ProdLog`'s
   `custom_script`-preset config (ADR-0040 decision 1) with an optional
   `correlate: {route, window}`. When configured, cross-check recent logs for
   that route/window on evaluation; a matching 5xx/panic downgrades a `:pass`
   with a `correlated_prod_error` evidence flag rather than silently trusting
   the green. Read-only, opt-in; unconfigured behavior is unchanged. This part
   has no dependency on any external skill.

## Consequences

- The capability works for every kazi user, not one operator's personal setup
  -- the schema is open and kazi ships its own producer (decision 2); an
  existing skill that happens to emit the same shape is a bonus input, never a
  requirement.
- Reuses proven machinery: the harness-invocation seam (`enrich/2`,
  `Kazi.Authoring`), the importer pattern (`GherkinImporter` et al.), and the
  existing surface-coverage meta-predicate. New work is one prompt template + a
  schema definition + one importer + one provider extension -- no new
  judgment layer inside kazi's deterministic core.
- `kazi spec discover` is non-deterministic and therefore explicitly a
  separate, opt-in command (not a flag silently enabled), mirroring `enrich`'s
  off-by-default posture and ADR-0013 §4's "clearly separated" consequence.
- Risk: a harness-discovered manifest is only as good as that run's discovery
  -- kazi does not grade its rigor, only holds its verdicts. Mitigated by the
  existing anti-gaming/enforcement layer (ADR-0042) and standing-mode re-runs,
  which surface a regression like any other predicate.
- Naming is deliberately generic (`usecase-manifest`, not "verify import") so
  the schema and the CLI surface never bake in a dependency on one person's
  skill library -- consistent with the OSS posture of a public repo (no
  audience-of-one surfaces, ADR-0015).

## Alternatives rejected

- **Import `/verify`/`/qualify`'s output directly as the mechanism** (the
  original draft of this ADR). Rejected: those are the operator's personal,
  unshipped Claude Code skills; a kazi user without them gets a dead command.
  Repeats the ADR-0015 "audience of one" mistake this project already
  corrected once.
- **Build live exploration/testing into kazi's deterministic core.** Rejected:
  duplicates what a harness-driven prompt can already do via the existing
  `enrich`/`Kazi.Authoring` seam; reverses ADR-0001 (not a harness) and
  ADR-0009 (no judgment layer in kazi itself).
- **A generic trust/confidence score on every predicate.** Rejected as
  premature generalization; fix the concrete, falsifiable failure mode
  (`/qualify`'s green-test-red-prod finding) narrowly, not speculatively.
- **kazi calls a specific Claude Code skill by name.** Rejected: inverts the
  dependency direction ADR-0001 establishes and hard-codes a personal tool
  into a public CLI surface.

## Related

- Extends ADR-0021's intended-vs-actual model with a fourth, empirically-
  discovered `I`-source and reuses its surface-coverage meta-predicate for the
  `A \ I` half.
- Reuses the harness-enrichment pattern established by ADR-0013 §4
  (`Kazi.Adopt.enrich/2`) for a new purpose (use-case discovery instead of
  live-predicate proposal).
- Sits alongside, does not modify, ADR-0050's `docs/specs/` tier and `kazi
  spec` verb family (this ADR adds `discover` and extends `import`).
- Consistent with ADR-0009 (grounded evidence and prompt projection, not
  judgment, lives in kazi) and ADR-0015 (no audience-of-one importers).

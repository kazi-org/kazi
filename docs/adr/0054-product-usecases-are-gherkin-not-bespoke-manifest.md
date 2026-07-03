# ADR 0054: Product-level use cases are Gherkin, not a bespoke manifest schema -- supersedes ADR-0051 decisions 1-3

## Status
Accepted

## Date
2026-07-02

## Supersedes
ADR-0051 decisions 1-3 (the open `usecase-manifest.json` schema, `kazi spec
discover` as a one-shot harness command, and a separate
`Kazi.Reconcile.UseCaseManifestImporter` module). ADR-0051 decision 4 (prod-log
predicate correlation) is RETAINED, unchanged -- see decision 6 below.

## Context

ADR-0051 closed a real gap (ADR-0021's intended-vs-actual model had no
*empirically discovered* `I`-source) by inventing a bespoke, kazi-owned JSON
schema for a "use-case manifest," a new `UseCaseManifestImporter` module, and a
`kazi spec import --from-usecase-manifest` flag. Review surfaced two problems
serious enough to warrant a correction rather than a patch:

1. **Self-inconsistency.** ADR-0050 -- one ADR earlier -- explicitly chose
   Gherkin over inventing a new grammar *because* Gherkin is a real, external,
   adopted standard: the whole point was that kazi is never the only tool that
   understands its own spec format. ADR-0051 then invented exactly the kind of
   bespoke format ADR-0050 had just argued against, for a closely related
   concept, one ADR later.
2. **Zero producers.** The bespoke schema had exactly one *hypothetical
   future* producer (`kazi spec discover`, not yet built) and zero existing
   ones anywhere -- a worse version of the "audience of one" failure ADR-0015
   already named, because there was not even an audience yet, only a plan for
   one.
3. **An unrealistic discovery mechanism.** `kazi spec discover` was designed as
   a *single* harness dispatch expected to replicate what `/verify`'s actual
   implementation does -- a ~500-line, phase-gated, tool-integrated Claude Code
   skill enforcing 100% use-case coverage with live testing. One "kazi-authored
   fixed prompt" cannot realistically match that, and the design had no
   objective way to know if a given dispatch's output was even complete.

Gherkin already resolves all three once looked at properly:

- Cucumber's **tag mechanism** (`@tag`) is a real, standard part of Gherkin,
  already used industry-wide to carry exactly this kind of metadata (role,
  priority, ownership, etc., commonly via `@key:value`-style conventions).
- A "use case" already *is* a Scenario. A directory of `.feature` files, tagged
  with role/priority/interface, one file per capability/domain, organized at
  the PRODUCT level instead of only the per-task level, IS a whole-system
  use-case catalog -- in the SAME format ADR-0050 already adopted, not a
  second, competing one.
- Wiring gaps (MISSING/STUB/ORPHAN) are a static structural question, already
  answered by the shipped surface-scanner + surface-coverage meta-predicate
  (ADR-0021, T13.4/T13.5). Bundling them into a use-case schema conflated two
  checks that already had two separate, working homes.
- A pass/fail verdict belongs to actually RUNNING the derived predicate
  (kazi's core competency), never to a discovery step's self-report.
- Real teams already practicing Cucumber/BDD have `.feature` files sitting in
  their repos TODAY -- an immediate, zero-discovery-needed import path a
  bespoke JSON schema could never have offered.

Separately, "how do we discover a manifest for an existing, undocumented
codebase" is better solved as an ITERATIVE CONVERGENCE -- the thing kazi is
actually good at -- than a one-shot prompt. The surface-scanner (T13.4,
shipped) already gives an OBJECTIVE list of what should be documented; kazi can
converge against "is every scanned element referenced by >=1 Scenario" the same
way it converges any other goal, instead of trusting one dispatch to have been
exhaustive.

## Decision

1. **Withdraw the bespoke `usecase-manifest.json` schema entirely.** No `kazi
   schema usecase-manifest`. ADR-0051 decision 1 is superseded.
2. **Product-level use cases are Gherkin `.feature` files**, using ADR-0050's
   existing `docs/specs/` tier, organized at the product/capability scope (one
   Feature per capability/domain, Scenarios as use cases) rather than only
   per-task. Tag Scenarios with kazi's own thin convention layered on real
   Gherkin tag syntax -- `@role:<role>`, `@priority:P0..P3`,
   `@interface:web|api|cli|sdk|grpc|background|ws`. The tag MECHANISM is
   standard Cucumber; the specific vocabulary is kazi's own, documented
   convention -- the same honesty ADR-0050 already applies to its Gherkin
   subset (a line-based parser, not a full gherkin dependency).
3. **Extend `Kazi.Reconcile.GherkinImporter`; do not add a sibling module.** It
   already parses `Feature:`/`Scenario:`/steps; extend it to also parse `@tag`
   lines and carry role/priority/interface onto the derived predicate --
   `@interface:web` derives a `browser` predicate, `@interface:api` derives
   `http_probe`/`custom_script`, absent tags default to today's `test_runner`
   behavior, BYTE-IDENTICAL for existing untagged `.feature` files. This
   generalizes the ADR-0050/T13.2 importer; it does not replace it. ADR-0051
   decision 3 (`UseCaseManifestImporter`) and the `--from-usecase-manifest`
   flag are withdrawn -- `kazi spec import <path>.feature` (ADR-0050, unchanged
   verb) already covers this once the importer reads tags.
4. **Wiring-gap detection is untouched.** Stays exactly on ADR-0021's
   surface-scanner + surface-coverage meta-predicate (T13.4/T13.5). Not part of
   this ADR's scope, not part of the Gherkin format.
5. **Discovery is `kazi init --discover`, an iterative convergence, not a
   one-shot prompt.** Extends the existing `kazi init`/adopt verb (ADR-0013),
   mirroring `--enrich`'s opt-in posture: writes a starter goal whose sole
   predicate is a new **manifest-coverage meta-predicate** -- every element the
   surface-scanner (T13.4) finds is referenced by >=1 Scenario across the
   product's `.feature` files (the SAME "ownership" check T13.5 already runs
   for predicates, retargeted at Scenario references instead). The predicate
   starts FALSE; running the goal via ORDINARY `kazi apply` dispatches the
   harness with grounded evidence -- "these N surface elements have no Scenario
   yet" (ADR-0009-style: kazi supplies the gap, the harness supplies the
   judgment of how to document it) -- converging over iterations instead of
   trusting one dispatch to be exhaustive. `--standing` keeps it re-converging
   as the codebase grows. This replaces ADR-0051 decision 2 entirely.
6. **Prod-log correlation (ADR-0051 decision 4) is RETAINED, unchanged.** It
   never depended on the manifest schema or the discovery mechanism -- an
   independent `Kazi.Providers.ProdLog`/`custom_script` extension.
7. **ADR-0051's own Status line is updated** (the one-line convention ADR-0026
   already established for a partially-superseded ADR) to record decisions 1-3
   superseded by this ADR and decision 4 retained.

## Consequences

- Real ecosystem interop: any repo already practicing Cucumber/BDD can `kazi
  spec import` its existing `.feature` files immediately, today, no discovery
  step needed.
- No orphan format: kazi never owns a schema with zero external producers.
- "Discovery" gets an objective completeness guarantee (every scanner-found
  element has a Scenario) instead of a one-shot prompt's unverifiable claim to
  have been thorough.
- Smaller total surface than ADR-0051 planned: no new schema doc, no new
  importer module, no new CLI flag beyond one that extends an EXISTING verb
  (`kazi init --discover`).
- `GherkinImporter`'s tag-reading extension must stay backward compatible: an
  untagged `.feature` file (ADR-0050's original per-task behavior specs)
  continues to derive a `test_runner` predicate exactly as before -- tags are
  additive, never required.
- The naming discipline ADR-0050 established ("behavior spec," not bare
  "spec") is unaffected and still applies at the product scope.

## Alternatives rejected

- **Keep the bespoke JSON schema, just document it better.** Rejected -- the
  problem is not documentation quality; it is duplicating a decision (adopt a
  real standard) the project already made one ADR earlier, for no offsetting
  benefit.
- **Keep `kazi spec discover` as a one-shot command, add human review.**
  Rejected as the PRIMARY mechanism (nothing prevents a human editing the
  converging `.feature` files at any point) -- an iterative, objectively-gated
  convergence is strictly better than a one-shot draft plus a hopeful review
  pass, and it is the SAME mechanism kazi already trusts for every other kind
  of goal.
- **Invent a different external standard** (a custom OpenAPI-adjacent
  "use-case" extension, or arc42-style prose). Rejected -- Gherkin is already
  adopted, already has a real tag mechanism, and kazi already has a tested
  importer for it; a second standard alongside Gherkin would just relocate the
  "why two formats" problem, not solve it.
- **Roll wiring-gap detection into the Gherkin tag vocabulary** (e.g.
  `@status:missing`). Rejected -- the surface-scanner already answers this
  deterministically without relying on a human or harness remembering to tag
  anything; a self-reported "missing" tag could rot exactly like a
  manually-maintained TODO list.

## Related

- Supersedes ADR-0051 decisions 1-3. Retains ADR-0051 decision 4 (prod-log
  correlation) and the underlying motivation from ADR-0051's context
  (ADR-0021's fourth, empirically-discovered `I`-source).
- Extends ADR-0050's `docs/specs/` tier and `GherkinImporter` (ADR-0021/T13.2)
  to the product/capability scope, and extends the importer's own capability
  (tag-reading) rather than adding a sibling module.
- Reuses ADR-0021 decision 3's surface-coverage meta-predicate pattern (T13.5)
  for a new target (Scenario-ownership instead of predicate-ownership) rather
  than inventing a second gap concept.
- Consistent with ADR-0009 (grounded evidence, not judgment, lives in kazi) and
  ADR-0002 (objective, checkable "done" -- applied here to "is the product spec
  complete," not just "does the code work").

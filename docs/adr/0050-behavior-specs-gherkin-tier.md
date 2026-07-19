# ADR 0050: Behavior specs -- a Gherkin doc tier between ADRs and `goal.toml`, wired to the existing importer

## Status
Accepted

## Date
2026-06-30

## Context

kazi's own documentation has a hole its own doc-tier model does not name. Today a
kazi feature is described by:

- **`docs/adr/`** -- WHY a decision was made (ADR-0036).
- **`docs/concept.md`** -- WHAT the system IS, architecture (ADR-0036; deliberately
  no `design.md`).
- **`docs/plan.md` / `docs/plans/ENN.md`** -- the task breakdown, one line per task
  (`acc:` is a hand-written prose acceptance sentence).
- **`goal.toml`** -- the machine-checkable predicates the `apply` loop reconciles
  against; ADR-0036 calls this "the executable spec."

None of these says, reviewably and before code is written, *what behavior is
being built* -- the piece that is neither a frozen decision, nor a task label,
nor a raw predicate. A WBS one-liner plus hand-authored predicates is the entire
"spec" for a task today, which is thin for anything non-trivial and gives no
traceable link from intent to predicate (a predicate's correctness is asserted,
not derived).

A survey of the current spec-driven-development landscape (GitHub spec-kit,
116k stars; AWS Kiro; OpenSpec, 58k stars; EARS notation; arc42/C4; AGENTS.md)
found the industry converging on exactly this missing piece: a reviewable
behavior artifact upstream of code, most portably expressed as Given/When/Then
(or EARS "when X, shall Y") requirement+scenario blocks, because that is the one
shape both a human can review and a machine can mechanically translate into
acceptance checks. OpenSpec's `changes/<slug>/{proposal.md, specs/*.md, tasks.md}`
with a propose -> apply -> archive lifecycle is the closest structural match to
how kazi already treats its own plan (ADR-0036's epic archival). AGENTS.md/
CLAUDE.md were confirmed NOT evolving toward this role -- they stay freeform
agent-operating instructions by design.

The decisive finding: **kazi already shipped the hard part and never used it.**
ADR-0021 / T13.2 built `Kazi.Reconcile.GherkinImporter` -- a pure, hermetic,
tested parser that turns `.feature` Given/When/Then Scenarios into grouped
`test_runner` acceptance predicates with stable, upsert-safe derived ids. `grep`
across `lib/` and `test/` confirms it is referenced nowhere outside its own
module and its own test file: no CLI verb, no workflow wires it up. It was built
to import an *external* target repo's existing specs (ADR-0021's "intended set"
for reconciliation), never framed as kazi's own first-class spec-authoring
convention for kazi's own feature work.

## Decision

1. **A new docs tier: `docs/specs/`.** One `<slug>.feature` file per behavior
   spec, using exactly the Gherkin subset `GherkinImporter` already accepts
   (`Feature:` / `Scenario:` / `Given`/`When`/`Then`/`And`/`But` steps). A spec
   MAY be paired with a short `<slug>.md` proposal note (why/scope, links to the
   driving ADR and WBS task) when the WBS one-liner is not enough context. This
   tier is used when a task's behavior is non-trivial enough to warrant a
   reviewable artifact before code; small tasks may keep just a WBS line + hand
   predicates as today.

   In prose, call this tier **"behavior specs"**, not bare "spec" -- kazi already
   overloads that word three ways (Elixir `@spec`, "goal spec" as a synonym for
   `goal.toml` per ADR-0036/concept.md, and ADR-0021's external-machine-spec
   sense). The `docs/specs/` directory and `.feature` extension are the
   disambiguating signal; docs should still say "behavior spec" on first mention
   in a section.

2. **An optional WBS field, `spec:`, on a plan task line** (alongside the
   existing `verifies:` / `deps:` / `acc:` fields), pointing at the task's
   `docs/specs/<slug>.feature`. This is metadata the global `/plan` skill's
   `parse_plan.py` should recognize generically (it is not kazi-specific), per
   the "enhance globally" rule -- extend the shared script, do not fork it into
   this repo.

3. **Wire the existing `Kazi.Reconcile.GherkinImporter` into the CLI**, giving it
   a first-class entrypoint (a new verb, e.g. `kazi spec import <path> --into
   <goal-ref>`, naming to be finalized in the epic consistent with ADR-0032's
   verb-consistency rule) that upserts a `.feature` file's Scenarios into a
   goal's `[[predicate]]` set. This is glue over code that already exists and is
   already tested -- no new parser, no new predicate provider, no new grammar.
   The result: **spec -> predicate becomes generated, not hand-typed** -- the
   traceability this ADR exists to close.

4. **Archive lifecycle mirrors the plan's.** When `trim_plan.py` (ADR-0036 L1)
   archives an epic whose tasks reference `docs/specs/*.feature` files, those
   files move verbatim to `docs/specs/archive/` alongside the epic, using the
   same lossless, git-diff-able mechanism -- no new archival concept invented.

5. **Docs land with the code (ADR-0034).** `docs/concept.md` gets a new
   subsection naming this tier next to 10a/10b; kazi's project `CLAUDE.md` adds
   `docs/specs/` to "read before changing anything" when relevant; the
   doc-lifecycle standing goal (T31.6) gains a broken-`spec:`-reference guard
   alongside its existing broken-ADR-reference check.

## Consequences

- Closes the traceability gap named in this ADR's Context: a human/agent writes
  a reviewable Given/When/Then spec, predicates are DERIVED from it (not
  asserted), the agent codes against grounded evidence (ADR-0009 is unchanged),
  and the spec archives alongside its epic.
- Small implementation surface. The parsing/predicate-derivation engine already
  exists and is already tested (T13.2); the new work is CLI wiring, a doc-tier
  definition, an optional WBS field, and archive-path glue -- not a new grammar
  or a new predicate provider.
- Resolves a concrete piece of dead code: `GherkinImporter` stops being an
  unreferenced module and becomes load-bearing, which also means its existing
  test suite starts guarding a real user-facing path instead of only itself.
- `docs/specs/` is optional, not mandatory, per task -- this does not obligate
  every WBS line to grow a spec file; it is for behavior worth reviewing before
  code.
- Naming risk: a fourth reading of "spec" enters the project's vocabulary
  despite the disambiguation effort. Mitigated by the directory/extension
  signature and by consistently writing "behavior spec" in docs generated under
  this ADR.

## Alternatives rejected

- **Adopt EARS prose (`requirements.md`, Kiro-style) as the grammar.** Rejected:
  kazi already has a hermetic, tested Gherkin importer; EARS's single-sentence
  templates ("When X, the system shall Y") are subsumed by a Gherkin
  When/Then pair, so adding EARS buys a second grammar for the same expressive
  range at the cost of a second parser with no existing test coverage.
- **Adopt spec-kit or OpenSpec wholesale** (their own `plan.md`/`tasks.md`/
  `constitution.md`). Rejected: this duplicates `docs/plan.md` (WBS) and
  `docs/adr/` (decisions/constitution) that kazi already has. Only the
  spec-authoring convention and the propose -> apply -> archive lifecycle shape
  are adopted, not the surrounding pipeline.
- **Prose-only specs (spec-kit-style user stories) instead of Gherkin.**
  Rejected as the default: prose still routes through the fuzzy, human-reviewed
  harness-drafting path (ADR-0021 decision 1 / T13.3) rather than a deterministic
  import. Gherkin is preferred whenever behavior is expressible as a scenario;
  the prose-via-harness path remains available (T13.3, unchanged) for behavior
  that resists formalization.
- **Do nothing; keep predicates hand-authored per task.** Rejected: this is the
  status quo the operator flagged as lacking a standard, and it leaves
  `GherkinImporter` permanently dead code.

## Related

- Extends the doc-tier map fixed by ADR-0036 (adds behavior specs as a sixth
  tier; does not alter the existing five).
- Reuses, does not change, ADR-0021's `GherkinImporter` (T13.2) and its
  prose-import path (T13.3).
- Consistent with ADR-0009 (grounded, evidence-driven prompts) and ADR-0034
  (docs land with code).

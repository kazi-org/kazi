# ADR 0071: A runtime `gherkin` predicate provider -- per-scenario verdict ingestion from any BDD runner

## Status
Proposed

## Date
2026-07-15

## Context

ADR-0050 (the `docs/specs/` behavior-spec tier) and T40.2 (`kazi spec import`)
give kazi an **author-time** path: a `.feature` file is parsed by
`Kazi.Reconcile.GherkinImporter` (ADR-0021/T13.2) into one **`custom_script`
scaffold** predicate per Scenario, grouped by Feature, written into a goal-file.
Each scaffold carries the scenario's steps as metadata and a placeholder command
that is RED until a human wires the real check. That is deliberate (ADR-0013:
scaffold, never guess) and useful for authoring, but it is **not runnable**: the
`.feature` states WHAT must hold, and the author-time verb never learns HOW to
check it.

kazi's first real production consumer -- **Sire** (`sirerun/sire`, issue #1107)
-- is built on Gherkin contracts (42 `.feature` files, 25 goal-files) and needs
the missing HALF: a way for a goal to **reconcile `.feature` scenarios natively
at run time**. Today Sire wraps each feature in a `custom_script`+godog shim that
collapses a whole feature to one opaque green/red predicate (Sire ADR 0031),
losing scenario-level granularity -- `kazi status` cannot show *which* scenario
regressed, which is the entire point of a predicate ladder.

The concrete ask (validated with the Sire fleet on #1107):

1. **Scenario-level granularity** -- one verdict per Scenario, grouped by
   Feature, so `kazi status` reads as an architecture dashboard.
2. **Runner-agnostic verdict ingestion** -- the SAME `.feature` should feed
   multiple test backends (godog for the API tier, Playwright/playwright-bdd for
   the browser tier). The mapping must key on **scenario identity, not the test
   framework**, so one Gherkin file drives multiple executors into one predicate
   set. The portable contract both emit is **cucumber-json**.
3. **Zero `.feature` change on adoption** -- goal-file-only migration
   (`custom_script` shim -> native provider).

This is a new **runtime predicate provider** (ADR-0002 territory), distinct from
ADR-0050's author-time tier. ADR-0050's acceptance explicitly scoped OUT "no new
predicate provider"; this ADR is the sibling that adds it.

## Decision

Add a runtime predicate provider **`gherkin`** (`Kazi.Predicate.kind ==
:gherkin`, ADR-0002) that reconciles a `.feature` file's Scenarios into
per-scenario verdicts by running a caller-supplied runner and ingesting its
**cucumber-json** (or a simple scenario->verdict map).

### 1. Load-time expansion (preserves one-predicate-one-verdict)

kazi's core invariant is **one `[[predicate]]` -> one verdict**. A `gherkin`
entry names a whole feature (many scenarios), so rather than special-casing a
one-to-many verdict, the loader **EXPANDS** a single `provider = "gherkin"`
entry, at goal-load, into **one real sub-predicate per Scenario**, reusing the
`GherkinImporter` parser for scenario identity:

- id = `<feature-slug>__<scenario-slug>` (the importer's existing derived id), so
  ids are stable and deterministic;
- grouped under one `[[group]]` per Feature (normalized id, ADR-0020);
- each sub-predicate keeps `:gherkin` kind and carries its `feature`, `scenario`,
  `steps`, and a reference to the SHARED runner spec.

`kazi status` therefore shows one line per scenario (the granularity ask), and
every leaf is a first-class predicate with exactly one verdict (the invariant).

**Scenario Outlines expand per Examples row.** A `Scenario Outline` runs once per
Examples row and cucumber-json reports one result per row, so the expander emits
**one sub-predicate per Examples row** (id suffixed with the row's key), giving
row-level `kazi status` visibility. This requires the expander to parse Examples
tables -- an extension of the importer, which currently collapses an Outline to a
single predicate and ignores Examples rows (T13.2). A plain `Scenario` remains
one predicate.

### 2. The runner runs ONCE per feature, memoized

The sibling sub-predicates of a feature share one runner invocation. Within a
reconcile pass the provider runs the runner **once per `(feature, runner)`**,
caches the parsed report, and each sub-predicate reads ITS scenario's verdict
from the shared report by scenario identity. A runner that a BDD framework runs
over the whole feature anyway (godog, playwright-bdd) is invoked once, not once
per scenario.

### 3. Runner-agnostic verdict ingestion (two formats)

The runner writes a machine report the provider parses. Two formats are
supported (per #1107):

- **`cucumber_json`** (default) -- the cucumber-json array both godog
  (`--format=cucumber`) and playwright-bdd emit. The provider matches each
  element's `(feature name, scenario name)` -- and, for outlines, the row key --
  to a sub-predicate.
- **`scenario_map`** -- a minimal `{"<scenario name>": "pass"|"fail"}` JSON
  object, for runners that do not speak cucumber-json.

The report is read from the runner's **stdout** by default, or from an explicit
**`report_path`** file when set (some runners only write a file).

### 4. Honest-unknown for un-run scenarios (ADR-0046)

A Scenario declared in the `.feature` but ABSENT from the report (the runner
skipped or did not emit it) evaluates to **`:unknown`**, never `:fail` -- kazi
never fabricates a verdict it did not observe (ADR-0046). A runner that fails to
execute at all makes every sub-predicate `:unknown` with the runner's stderr as
evidence.

### 5. Goal-file schema

```toml
[[predicate]]
provider       = "gherkin"
feature        = "docs/specs/storage-store.feature"
verdict_format = "cucumber_json"        # | "scenario_map"; default "cucumber_json"
runner_cmd     = "bash"                  # the executable (resolved on PATH)
runner_args    = ["scripts/storage-contract.sh"]
# report_path  = "build/cucumber.json"   # optional; omit => read runner stdout
# acceptance   = true                     # inherited by every expanded sub-predicate
# group        = "..."                    # optional explicit group; default = the Feature
```

Adoption is goal-file-only: Sire swaps its `custom_script` shim block for the
block above, with **zero change to the `.feature`** (Sire ADR 0031's promise).

### 6. The provider OWNS its config-key atoms (learned from #1112)

The `gherkin` provider module references `feature`, `scenario`, `steps`,
`verdict_format`, `runner_cmd`, `runner_args`, `report_path` as literal atoms, so
`ensure_provider_loaded(:gherkin)` interns them at goal-load. This avoids the
release-only load failure #1112 hit, where the importer's `feature/scenario/steps`
keys were interned by NO loaded module in the release binary. (The loader also
interns them defensively via `@gherkin_doc_keys` after #1112.)

## Consequences

**Positive**

- Sire migrates off its per-feature `custom_script`+godog shim to native,
  per-scenario reconcile with no `.feature` changes -- the #1107 keystone.
- One `.feature` drives godog (API) AND Playwright (browser) into ONE predicate
  set, keyed on scenario identity: deterministic, DRY spec->browser coverage.
- `kazi status` becomes a scenario-granular architecture dashboard.
- Reuses the ADR-0021/T13.2 parser; no new grammar, no gherkin dependency.

**Negative / costs**

- A new provider kind + a runtime evaluator that shells out and parses a report
  -- more surface than the author-time verb.
- Load-time expansion makes one goal-file line become N predicates; `--explain`
  and status output must make the expansion legible (which feature a scenario
  came from).
- The per-row Outline expansion couples the predicate SET to the Examples table:
  editing the table changes ids/count. Documented; the row key is derived
  deterministically from the row's values.
- Runner memoization adds per-reconcile caching keyed on `(feature, runner)`;
  must be correct under `--parallel`/fleet (cache is per goal-eval, not global).

## Alternatives considered

- **Single aggregate predicate per feature** (no expansion): simplest, closest
  to today's shim, but keeps `kazi status` coarse -- rejected, it loses the
  scenario granularity that is the whole ask.
- **Author-time expansion via `kazi spec import`** (extend the merged verb to
  emit N `custom_script` predicates sharing a runner + report): reuses shipped
  code and needs no new provider, but it is a STATIC materialize step, not live,
  and adoption is not goal-file-only -- rejected against Sire's requirements.
- **Keep the `custom_script`+godog shim** (status quo): one opaque verdict per
  feature; rejected -- it is exactly what #1107 asks to retire.

## Relationships

- **Extends** ADR-0050 (author-time behavior-spec tier) with its runtime sibling;
  the two share the `docs/specs/` tier and the ADR-0021 parser.
- **Uses** ADR-0021/T13.2 (`GherkinImporter` parser) for scenario identity, and
  ADR-0002 (adding a provider kind).
- **Sibling of** ADR-0040 (`custom_script`, the generic command-runner) -- but
  `gherkin` fans one runner run into per-scenario verdicts, which `custom_script`
  cannot.
- **Honors** ADR-0046 (honest-unknown) for un-run scenarios.
- **Motivated by** issue #1107 (Sire, the first production consumer).
- **Learns from** issue #1112 (a provider must intern its own config-key atoms).

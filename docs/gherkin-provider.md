# The `gherkin` predicate

`gherkin` reconciles a whole `.feature` spec (ADR-0050) at run time into
**per-scenario verdicts**. A single goal-file `[[predicate]]` names one feature;
the loader **expands** it, at goal-load, into one real sub-predicate per Scenario
— and one per Examples row for a `Scenario Outline` — so `kazi status` shows a
scenario-granular dashboard while kazi's one-`[[predicate]]`-to-one-verdict
invariant is preserved (ADR-0071).

Introspect every key at runtime with:

```
kazi schema gherkin
```

## `spec import` vs. `provider = "gherkin"` — two mechanisms, two needs

kazi has **two** ways to turn a `.feature` behavior spec (ADR-0050) into
predicates, and they are not interchangeable. Reach for the one that matches
where the verification actually lives.

| | [`kazi spec import`](specs/README.md) (E40, ADR-0050/0054) | `provider = "gherkin"` (this epic, ADR-0071) |
|---|---|---|
| **When** | Author-time, once — a human runs the verb | Run time, every reconcile pass |
| **What it produces** | Scaffolds one **RED `custom_script`** (or, `--lower scenario`, one `scenario`) predicate per Scenario, **written into** the goal-file for a human to wire to a real check | Binds the **whole feature** to a caller-supplied BDD runner and ingests its machine report into **per-scenario verdicts** — nothing is written into the goal-file per scenario |
| **Who owns the verdict** | The command you wire into each scaffolded `custom_script` | The BDD runner (godog, playwright-bdd, …) named by `runner_cmd` |
| **The `.feature`** | A source you import **from** (its Scenarios become editable predicate stubs) | Bound **as-is** at run time — **zero change**, editing it re-expands the sub-predicate set at the next load |
| **Use it when** | You want each Scenario as a separate, hand-tuned predicate you'll flesh out | You already have a BDD runner that executes the feature and you want its native verdicts, scenario-granular, with no per-scenario wiring |

In short: `spec import` is a **scaffolding verb** (draft predicates for a human
to finish), `gherkin` is a **runtime provider** (native BDD verdicts, no
scaffolding). This page documents the latter.

## Goal-file schema

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

| Key              | Required | Meaning |
|------------------|----------|---------|
| `provider`       | yes      | `"gherkin"` |
| `feature`        | yes      | Path to the `.feature` file, resolved relative to the workspace (the directory the runner also executes in). A missing or empty value is a named load error. |
| `verdict_format` | no       | `"cucumber_json"` (default) or `"scenario_map"`. Any other value is a named load error. |
| `runner_cmd`     | no*      | The runner executable, resolved on `PATH`. Shared by every expanded sub-predicate. |
| `runner_args`    | no*      | Arguments passed to `runner_cmd`. |
| `report_path`    | no       | Read the machine report from this file instead of the runner's stdout. |
| `acceptance` / `guard` / `held_out` | no | Inherited by every expanded sub-predicate. |
| `group`          | no       | An explicit declared `[[group]]` id for the sub-predicates. Default: one group synthesized per Feature (normalized Feature name). |

\* `runner_cmd`/`runner_args` define the shared runner and are consumed by
verdict ingestion (T62.2); the load-time expansion carries them onto every
sub-predicate.

## Load-time expansion

One `provider = "gherkin"` entry becomes N sub-predicates, each with
`kind = :gherkin`:

- **id** — `<feature-slug>__<scenario-slug>` (the same identity the Gherkin
  importer derives), so ids are deterministic and stable across reloads:
  re-loading an edited `.feature` upserts, it never duplicates.
- **grouping** — all of a feature's sub-predicates are placed under one
  `[[group]]` per Feature (a normalized-id group synthesized from the Feature
  name, ADR-0020), unless an explicit `group` is set.
- **Scenario Outline** — expands to **one sub-predicate per Examples row**, id
  suffixed with the row key, with `<placeholder>` cells substituted into the
  steps. Editing the Examples table changes the id/count of the row
  sub-predicates — this is intentional (the table IS the predicate set).

## Verdict ingestion (T62.2)

At reconcile time the shared runner is executed and its machine report ingested
into per-scenario verdicts.

### The runner runs once per feature (memoized)

The runner named by `runner_cmd`/`runner_args` runs **exactly once per
`(feature, runner)` per reconcile pass**, memoized across all the sibling
sub-predicates the feature expanded into — not once per scenario. A BDD runner
that already executes the whole feature (godog, playwright-bdd) is invoked once;
each sub-predicate then reads ITS scenario's verdict from the single parsed
report. The memo lives for one pass (keyed on the iteration): a fresh reconcile
pass re-runs the runner for a fresh verdict, but the N siblings within a pass
never re-run it. Because kazi observes a predicate vector sequentially in one
process, the cache is per-goal-eval, never global — correct under `--parallel`
and across a fleet.

### Report source and formats

The report is read from the runner's **stdout** by default, or from the
**`report_path`** file when set (the runner's captured stream — its stdout and
stderr merged — is retained as evidence either way). Two `verdict_format`s are
supported:

- **`cucumber_json`** (default) — the cucumber-json array both godog
  (`--format=cucumber`) and playwright-bdd emit. A scenario element passes iff it
  has steps and every step's `result.status` is `"passed"`; any other step
  status (failed / undefined / pending / ambiguous / skipped) or a step-less
  element is a fail. `background` elements are ignored.
- **`scenario_map`** — a minimal `{"<scenario>": "pass"|"fail"}` JSON object, for
  runners that do not speak cucumber-json.

Each sub-predicate matches its own verdict by scenario identity — the `scenario`
name matched **VERBATIM** against the report. A `Scenario Outline` row also tries
its example-substituted name (`Payment declined for <card>` → `... expired`)
before the raw outline name, so a runner that substitutes the row value into the
reported scenario name still matches. The report is parsed with string keys and
scenario names are matched as strings (no `String.to_atom/1` on report content),
so a goal ingests identically under `mix` and the release binary.

### Honest-unknown (ADR-0046)

kazi never fabricates a verdict it did not observe:

- A Scenario present in the `.feature` but **absent from the report** →
  `:unknown`, never `:fail` (the evidence lists the report's available
  scenarios).
- A runner that **fails to execute at all** — could not spawn, or produced no
  parseable report (empty/garbled output, or an unreadable `report_path`) →
  **every** one of its sibling sub-predicates is `:unknown`, with the runner's
  captured output (its stderr) as evidence. A **nonzero exit is not** a failure
  to observe: a BDD runner exits nonzero precisely when a scenario fails, and its
  report still lists every scenario's real verdict, so the exit code never gates
  ingestion.

## Relationships

- **ADR-0071** — the authoritative design (per-scenario verdict ingestion from
  any BDD runner).
- **ADR-0050** — the `docs/specs/` behavior-spec tier this reconciles at run time.
- **ADR-0046** — honest-unknown for an un-run / un-ingested scenario.
- **`scenario` predicate** ([scenario-predicate.md](scenario-predicate.md)) —
  the pin-and-replay sibling for a SINGLE Scenario through a surface provider.

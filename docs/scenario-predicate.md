# The `scenario` predicate

`scenario` binds one Gherkin Scenario in a `.feature` spec (ADR-0050) to a
committed, replayable **pin**, and passes only when that pin validates AND
**replays green** through the underlying surface provider (ADR-0064). No
demonstration transcript or agent claim can satisfy it — the truth is what the
surface provider *observes* on replay.

It does not run a check of its own: it **delegates**. A pinned browser Scenario
replays through `Kazi.Providers.Browser`; a pinned cli Scenario through the
`:cli` provider. The pin's `trace` is expressed in exactly that surface
provider's config vocabulary, so a pin is a compile target onto an existing
provider, not a second execution grammar — it inherits `samples`/consecutive-pass
and every assertion type for free.

Introspect every key at runtime with:

```
kazi schema scenario
```

## An unpinned / stale / invalid pin is failing work, not an error

The provider classifies the pin before any replay, and the three non-pinned
outcomes are all `:fail` — real, actionable work the loop routes an agent at,
never an ambiguous provider `:error`:

- **`:unpinned`** — no pin file exists yet. Demonstrate the Scenario and mint one.
- **`{:stale, :spec_changed}`** — the Scenario text changed since the pin was
  minted (its `scenario_sha` no longer matches). Re-demonstrate it.
- **`{:invalid, [reasons]}`** — the pin is structurally unfaithful (e.g. a
  `Then` step maps to no assertion) or malformed. Repair or re-mint it.

Each `:fail` carries `%{pin_state:, pin_path:, scenario_steps:, reasons:}` so the
fixer knows which artifact blocks the predicate and why.

Only a genuinely un-runnable condition is `:error`: the spec file is missing
(`:spec_not_found`), the named Scenario is absent from it (`:scenario_not_found`),
or the target surface has no registered provider (`:surface_unavailable`).

## Only `:pinned` replays, and the replay is the pass

On a `:pinned` classification the pin's `trace` is merged **over** the predicate's
passthrough config and handed to the surface provider, which replays it. The
provider returns the delegate's status/score/direction **verbatim**, with its
evidence **extended** by `%{scenario:, spec:, surface:, pin_state: :pinned,
inputs: <generated>}`. A red replay is a `:fail` carrying the delegate's own
evidence (e.g. the failing assertion) plus those scenario fields.

## Input generators and `{{placeholder}}` substitution

A pin's `inputs` map names each `{{placeholder}}` its trace interpolates and the
generator kind that fills it. Before every replay the provider substitutes a
**freshly generated value** for each placeholder — anywhere it appears, in a step
or an assertion — so replays are collision-free (no "name already taken" on the
second run) and a fixer cannot hardcode a happy path against known test data
(ADR-0064 decision 2). The generated values are recorded in evidence under
`inputs:` so a failing replay is reproducible.

```json
"inputs": { "pat_name": "unique_slug" },
"trace": {
  "steps": [{ "action": "type", "selector": "#name", "text": "{{pat_name}}" }],
  "assertions": [{ "type": "text", "selector": "#token-name", "equals": "{{pat_name}}" }]
}
```

Generator kinds:

| kind | produces |
|------|----------|
| `unique_slug` | the placeholder name, a hyphen, and 8 hex chars (`pat_name-1a2b3c4d`). |
| `random_email` | `<12 hex>@example.com` (the RFC 2606 reserved domain). |
| `random_string:<n>` | `n` lowercase-alphanumeric chars (`n` a positive integer). |

A placeholder whose declared generator kind is unknown (or a `random_string:`
with a non-positive / non-integer length) is a pin defect: the replay fails loudly
as `{:invalid, [{:unknown_generator, <name>}]}` rather than driving a literal
`{{name}}` into the surface.

## Config keys

| key | required | meaning |
|-----|----------|---------|
| `spec` | yes | Path to the `.feature` file holding the Scenario. |
| `scenario` | yes | The Scenario name to bind and replay. |
| `surface` | no | Which surface provider replays the pin: `"browser"` (default) or `"cli"`. |
| `pin` | no | Path to the pin artifact. Defaults to `docs/specs/pins/<derived-id>.pin.json` (the Feature+Scenario slug the Gherkin importer mints, so it is upsert-safe). |
| `repin` | no | Re-mint policy: `"auto"` (default) or `"manual"`. |

Every other key passes through **unchanged** to the delegate provider, so its own
config (`url`, `samples`, the `cmd` test seam, …) works exactly as when authoring
against that provider directly.

## Example

```toml
[[predicate]]
id = "pat-create-download"
provider = "scenario"
spec = "docs/specs/pat.feature"
scenario = "User can create and download a PAT"
surface = "browser"
```

See [ADR-0064](adr/0064-scenario-predicates-demonstrate-then-pin.md) for the
demonstrate-then-pin decision and the structural-faithfulness floor.

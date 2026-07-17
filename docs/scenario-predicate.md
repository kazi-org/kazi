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

## The truth invariant

Stated verbatim in [ADR-0064](adr/0064-scenario-predicates-demonstrate-then-pin.md)
(decision 1):

> the predicate is `:pass` iff the committed pin validates (decision 2) and
> REPLAYS green through the underlying surface provider. No demonstration
> transcript, agent report, or any other claim can satisfy it. An inability to
> replay at all (Playwright missing, malformed pin schema) is `:error`, never
> `:fail` (ADR-0002).

## The pin-state lifecycle

The provider classifies the pin before any replay. Every state except `:pinned`
is `:fail` — real, actionable work the loop routes an agent at, never an ambiguous
provider `:error`. The states and what moves between them:

```
                        (no pin file yet)
                               │
                               ▼
   demonstrate + mint    ┌───────────┐
   ────────────────────► │ :unpinned │
                         └───────────┘
                               │  a pin is committed
                               ▼
                         ┌───────────┐  Scenario text edited
             ┌───────────│  :pinned  │───────────────────────► {:stale,
             │           └───────────┘  (scenario_sha mismatch)  :spec_changed}
             │                 ▲                                      │
   replay    │                 │  re-demonstrate / repair             │
   green ►  :pass              └──────────────────────────────────────┘
             │                 ▲
             │                 │  fix the trace/map
             │           ┌──────────────┐  trace not schema-valid, or a
             └───────────│ {:invalid,_} │◄─── When maps to 0 steps / a
      (a red replay          └──────────────┘   Then maps to 0 assertions
       is :fail, not
       a state change)
```

- **`:unpinned`** — no pin file exists yet. A **demonstrator** (ADR-0064
  decision 3) drives the surface, records a pin, and commits it.
- **`{:stale, :spec_changed}`** — the Scenario text changed since the pin was
  minted (its `scenario_sha` no longer matches the current normalized Scenario).
  The pin is re-demonstrated wholesale; a stale Scenario reports stale even when
  the pin is also otherwise invalid.
- **`{:invalid, [reasons]}`** — the pin is structurally unfaithful (a `When`
  mapping to zero trace steps, a `Then` to zero assertions), addresses a trace
  index that does not exist, references an unknown generator, or is malformed
  JSON. Repair or re-mint it.
- **`:pinned`** — the pin validates and is replayed. A **green** replay is
  `:pass`; a **red** replay is `:fail` carrying the delegate's evidence (this is a
  capability regression, not a pin-state change).

Each non-pinned `:fail` carries `%{pin_state:, pin_path:, scenario_steps:,
reasons:}` so the fixer knows which artifact blocks the predicate and why.

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

## The pin artifact

One JSON file per Scenario, at `docs/specs/pins/<derived-id>.pin.json`. It is
committed and reviewable like any other change. A complete browser pin, annotated:

```jsonc
{
  "pin_version": 1,                       // schema version; only 1 validates today
  "spec": "docs/specs/pat.feature",       // the .feature file this realizes
  "scenario": "User can create and download a PAT",  // the bound Scenario name
  "scenario_sha": "<hex>",                // SHA-256 of the normalized Scenario text;
                                          // a Scenario edit makes the pin :stale
  "surface": "browser",                   // which surface provider replays it
  "minted": { "commit": "0f1e2d3c4b5a" }, // provenance (informational)
  "inputs": { "pat_name": "unique_slug" },// {{placeholder}} -> generator kind
  "trace": {                              // the realization, in the SURFACE
    "url": "http://localhost:4000/settings/tokens",  // provider's OWN config vocab
    "steps": [
      { "action": "click", "selector": "#new-token" },
      { "action": "fill", "selector": "#name", "value": "{{pat_name}}" },
      { "action": "click", "selector": "#generate" }
    ],
    "assertions": [
      { "type": "visible", "selector": "#token-value" },
      { "type": "text", "selector": "#token-name", "exact": "{{pat_name}}" }
    ],
    "timeout_ms": 30000
  },
  "map": [                                // each Given/When/Then -> the trace
    { "step": "I create a token", "steps": [0, 1, 2], "assertions": [] },
    { "step": "the token value is shown", "steps": [], "assertions": [0, 1] }
  ]
}
```

`trace` is kept string-keyed and verbatim: it is a **compile target onto the
surface provider**, so its keys are exactly that provider's config vocabulary
(`url`/`steps`/`assertions`/`timeout_ms`/`samples` for `browser`), and it inherits
`samples`/consecutive-pass and every assertion type for free. `map` is the
structural-faithfulness floor: **every `When`-class step must map to ≥ 1 trace
step and every `Then` to ≥ 1 assertion**, or the pin is `{:invalid, _}`. A
`Given` needs no mapping (it describes a precondition the trace may reach without
a distinct step). Indices under `steps`/`assertions` in a `map` entry address the
trace's `steps`/`assertions` lists; an out-of-range index is invalid.

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
  "steps": [{ "action": "fill", "selector": "#name", "value": "{{pat_name}}" }],
  "assertions": [{ "type": "text", "selector": "#token-name", "exact": "{{pat_name}}" }]
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

## Hand-authoring a scenario predicate

The loop can mint a pin for you (the demonstrator, ADR-0064 decision 3), but a pin
is an ordinary committed artifact you can also write by hand. To author one end to
end:

1. **Write the Scenario** in a `docs/specs/*.feature` spec — the prose `Given` /
   `When` / `Then` of the capability.
2. **Declare the predicate** in your goal-file: `provider = "scenario"`, the
   `spec` path and `scenario` name, and the `surface` that replays it. Add
   `inputs = { <name> = "<generator>" }` for any value that must be fresh per run.
3. **Write the pin** at `docs/specs/pins/<derived-id>.pin.json` (or the explicit
   `pin` path). Fill `scenario_sha` with the SHA-256 of the normalized Scenario
   (kazi computes it; a wrong value simply reads as `:stale`). Author the `trace`
   in the surface provider's own config vocabulary, and `map` each `When` to the
   trace steps and each `Then` to the assertions that realize it.
4. **Use `{{placeholders}}`** wherever a value must be unique per replay
   (a token name, an email), and declare each in `inputs` — see the generator
   table above. Every `{{name}}` must have an `inputs` entry or the pin is invalid.
5. **Verify** it: the pin classifies `:pinned` against the current Scenario, and
   replays green through the surface. `kazi apply <goal> --workspace .` converges
   it; `kazi schema scenario` lists every config key.

## A worked, replayable example

The repo ships a complete, genuinely replayable example (ADR-0064, T49.5):

| artifact | path |
|----------|------|
| goal-file | `priv/examples/scenario_hello.goal.toml` |
| spec | `docs/specs/scenario_hello.feature` |
| pin | `docs/specs/pins/scenario-hello__a-visitor-sees-the-greeting.pin.json` |
| fixture page | `priv/examples/scenario_hello_fixture.html` |

The Scenario is *"A visitor sees the greeting"*; the pin's browser trace opens the
fixture page and asserts the `#greeting` heading is visible and reads
`Hello, kazi!`. Run it against a real browser by serving the fixture and applying
the goal:

```sh
python3 -m http.server 8080 --directory priv/examples &
kazi apply priv/examples/scenario_hello.goal.toml --workspace .
```

`test/kazi/examples/scenario_hello_example_test.exs` proves the same three things
hermetically: the goal-file loads, the committed pin classifies `:pinned` through
the real validator, and the pin replays green through the stub-runner seam — so CI
needs no browser.

## PAT-style walkthrough

The capability ADR-0064 opens with is *"a user can create and download a personal
access token (PAT)"* — a multi-step journey (navigate, submit a form, a server
round-trip, a download) that no single assertion captures. As a scenario predicate:

1. The **Scenario** states the intent in prose:

   ```gherkin
   Scenario: User can create and download a PAT
     Given I am signed in
     When I create a token named "{{pat_name}}"
     Then the token value is shown
   ```

2. The **predicate** binds it, generating a fresh token name each replay so the
   second run never collides with the first:

   ```toml
   [[predicate]]
   id = "pat__user-can-create-and-download-a-pat"
   provider = "scenario"
   spec = "docs/specs/pat.feature"
   scenario = "User can create and download a PAT"
   surface = "browser"
   inputs = { pat_name = "unique_slug" }
   ```

3. The **pin** (see the annotated reference above) realizes the `When` as the
   click/fill/click trace steps and the `Then` as the `#token-value` visibility +
   `#token-name` text assertions, with `{{pat_name}}` substituted fresh per replay.

The predicate is green only when a real browser, driving that trace, observes the
token being created and shown — never because an agent said it built the feature.

See [ADR-0064](adr/0064-scenario-predicates-demonstrate-then-pin.md) for the
demonstrate-then-pin decision, the demonstrator role, and the
structural-faithfulness floor.

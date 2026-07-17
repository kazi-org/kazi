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
- **`{:stale, :code_drift}`** — a `:pinned` pin whose replay went **red** while
  `HEAD` has moved past the pin's minted commit (T49.8). The code changed, so a red
  replay is plausibly the pin gone stale rather than a regression — re-demonstrate.
- **`:stale_manual`** — a stale pin (spec-changed or code-drift) under `repin =
  "manual"`. Parked: **never auto-demonstrated**, deliberately operator work.
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

## Demonstrator dispatch (ADR-0064 d3)

When the blocker is the PIN — `:unpinned` or `{:stale, :spec_changed}` — the loop
does not dispatch a **fixer** (which patches code); it dispatches a
**demonstrator**. This is a distinct loop action, `:dispatch_demonstrator`, routed
purely on the failing-predicate evidence (its `pin_state`) through the same
dispatch machinery as the fixer — no new decision branch. Its job: operate the
running surface, accomplish the Scenario literally, and write the pin that encodes
how. `repin = "manual"` opts a predicate out of automatic demonstration.

The demonstrator is **write-disjoint from the fixer** (T49.6 role-scoped
enforcement): it may write ONLY the pin path; code, specs, and the goal-file are
read-only to it. So it cannot patch the app to make its own demonstration pass — if
the capability is broken, the demonstration fails honestly and becomes grounded
evidence for the next fixer dispatch. The fixer, conversely, has pins and specs in
its read-only set — it cannot forge the grader.

**Born reproducible — the acceptance gate.** A freshly minted pin is accepted only
if, in the same dispatch, it both **validates** (the T49.1 contract) and **replays
green** through the surface provider — exactly what evaluating the predicate
checks. If either fails, the write is **discarded** (the pin file deleted) and the
demonstration is recorded as `%{demonstration: :rejected, reasons: [...]}`. So the
agentic, nondeterministic authoring is quarantined at demonstration time and
evaluation stays deterministic; a demonstration that cannot be reproduced never
lands. A harness error or crash is best-effort — no pin is kept and the loop
survives.

## Repin lifecycle (T49.8, ADR-0064 d4)

An accepted pin is stamped with `minted.commit = HEAD` at acceptance time (the
`minted` block is provenance only — it never affects validation). That commit is
what lets a later **red replay** be classified honestly:

- **`HEAD` moved since mint** → `{:stale, :code_drift}` → a **demonstrator**
  re-demonstration. On a successful repin the run records the old→new pin as a
  unified diff in evidence (`%{repin_diff: "..."}`), so a reviewer sees exactly
  what changed — selector rot distinguished from a genuine behaviour change.
- **`HEAD` still at the minted commit** → a plain `:pinned` `:fail` — a real
  **regression**, routed to the **fixer** (not a repin). The capability broke
  without the surface moving.

**`repin` policy** (a `scenario` config key):

- `"auto"` (default) — at most one re-demonstration per iteration; the loop mints
  the new pin itself.
- `"manual"` — a stale pin parks as `:stale_manual` and is **never
  auto-demonstrated**. Re-pinning is deliberately operator work (surfaced in the
  attention queue), not something the loop resolves on its own.

**`capability_unreachable`.** Two consecutive failed demonstrations with **no
intervening code change** means re-demonstrating is futile — the run terminates
`:stuck` with cause `capability_unreachable` (rather than looping demonstrations or
draining the budget). It ranks as **needs-a-human** in the attention queue: the
capability is broken or the surface unavailable, not something another dispatch or
a bigger budget fixes. The cause is projected onto the run's
`outcome_cause_class`, so it survives after the loop process is gone.

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

## The two roles

A scenario predicate is written by one role and consumed by another. They are
deliberately separate, because the whole point is that the party who *builds* the
capability is not the party who *decides it works*.

| role | does | when |
|---|---|---|
| **Demonstrator** | Performs the capability once against a real surface and mints the pin — the recorded trace of what actually happened. Answers *"here is the thing working."* | Once, at `:unpinned` (and again on `:stale`, when the Scenario text changed) |
| **Replayer** | Drives the committed pin's trace and reports whether the capability still holds. Never authors the trace, never edits the pin. Answers *"does it still work?"* | Every evaluation, forever |

The split is the honesty guarantee. A fixer agent is a **replayer**: it can make
the capability work, but it cannot rewrite what "working" means, because the pin
is committed and the replay is the pass (see *Only `:pinned` replays*). An agent
that could mint its own pin could demonstrate a capability that was never asked
for and call the goal green.

## Standing capability monitors

The definition of done ends at *"deployed and verified live"*. A **monitor** makes
that step a predicate rather than a ritual: it replays a committed pin against a
**deployed** URL, so green means a real browser just performed the capability in
production.

There is no monitor machinery. A monitor is the ordinary scenario predicate with
three properties composed:

| property | effect |
|---|---|
| the goal is `standing = true` | it never finishes — it holds the predicates true and re-converges on drift |
| `url` names a **deployed** host | the replay drives production, not localhost |
| `samples = N` | N **consecutive** passes required, so a flaky surface cannot show green on one lucky run |

```toml
standing = true          # MUST precede the first [table] header — see below

[[predicate]]
id = "signup-still-works"
provider = "scenario"
spec = "docs/specs/product/onboarding.feature"
scenario = "A new user signs up and lands on the dashboard"
url = "https://app.example.com"
samples = 3
```

Worked example: [`priv/examples/capability_monitor.goal.toml`](../priv/examples/capability_monitor.goal.toml).

`samples` is the **monitor's** knob, not part of the pin: the pin records what the
capability *is*; `samples` is how hard *this* monitor probes it. It passes through
to the delegate unchanged, which requires N consecutive passes and reports
envelope-v2 `score` = passing runs, `direction: higher_better`.

**A TOML footgun worth naming.** `standing = true` must sit **above the first
`[table]` header**. In TOML a bare key written after a header belongs to *that*
table, so `standing = true` placed below `[metadata]` silently becomes
`metadata.standing` — the goal loads as an ordinary converge-and-stop one, with no
error and no warning. It reads as declared and behaves as not.

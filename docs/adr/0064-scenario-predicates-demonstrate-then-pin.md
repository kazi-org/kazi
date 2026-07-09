# ADR 0064: Scenario predicates -- capability-level verification by demonstrate-then-pin

## Status
Accepted

## Date
2026-07-08

## Refines / depends on
ADR-0002 (pass/fail/error discipline), ADR-0009 (kazi supplies grounded evidence,
never judgment), ADR-0013 (the opt-in, harness-driven enrichment seam --
`Kazi.HarnessAdapter`), ADR-0021 (intended-vs-actual; `GherkinImporter`),
ADR-0042 (anti-gaming enforcement: `read_only_paths`, held-out predicates),
ADR-0043 (the DEMONSTRATION-vs-CLAIM evidence tiers and the earns-first-class
test), ADR-0050 (behavior specs: the `docs/specs/` Gherkin tier), ADR-0053 (the
`:browser` UI-assertion pack and the `:cli` provider -- this ADR's compile
target), ADR-0054 (tagged Scenarios are the product use-case catalog; this ADR
extends its decision 3 lowering with an opt-in target), ADR-0055 (landing is
part of convergence; the versioned controller-owned process contract),
ADR-0058 (stuck causes; economy attribution).

## Context

The predicate catalog now covers code truth (`:tests`, `:static`, `:coverage`,
`:property`, `:mutation` -- ADR-0043), artifact truth (`:cli` -- ADR-0053),
surface truth (the `:browser` assertion pack: `form_validation`,
`console_clean`, `a11y`, `visual` -- ADR-0053), and live telemetry
(`:http_probe`, `:metrics`, `:prod_log`). The intent tier exists too: behavior
specs are Gherkin Scenarios in `docs/specs/` (ADR-0050), tagged
`@role:`/`@priority:`/`@interface:` at product scope as the use-case catalog
(ADR-0054).

What is still missing is the level a goal author actually wants to state:
**"a user can create and download a personal access token."** That is not a
form assertion (ADR-0053 covers "the form validates input" already); it is a
*capability* -- a multi-step journey across navigation, a form, a server
round-trip, and a file download, whose truth is "a user operating the shipped
surface can accomplish this end to end." There is today no standard,
machine-checkable way to verify a capability. This is the industry's gap, not
just kazi's: Gherkin has the *language* but its execution glue (step
definitions) is per-repo code that humans write and let rot; Playwright has
*execution* but no intent layer; nothing connects intent to execution without
a human hand-maintaining the join.

kazi has already walked into this gap and left it unowned. ADR-0054 decision 3
lowers an `@interface:web` Scenario to a `:browser` predicate -- but a
`:browser` predicate's truth lives in its `steps`/`assertions`: concrete
selectors and actions. A Scenario's steps are prose ("When they create a PAT
named X"). Nothing owns prose -> executable. The three available outcomes are
all bad:

1. **Hand-author the steps** per Scenario: brittle, unverifiable against the
   spec's intent, and exactly the non-standard artisanal mess the behavior-spec
   tier was created to end.
2. **Lower to `test_runner`** (the untagged default): assumes Cucumber step
   definitions exist -- true only for repos already practicing BDD, and even
   then kazi is trusting the repo's own glue code as the grader.
3. **Emit a vacuous probe** ("the page loads"): the predicate passes while the
   capability may not exist at all.

Meanwhile every piece needed to close the gap is already shipped or decided:
the reconcile loop dispatches agents against failing predicates; ADR-0013's
`enrich/2` established the fixed-prompt, validate-before-accept,
harness-driven authoring role; the `:browser`/`:cli` providers are hermetic,
deterministic replay engines with an assertion vocabulary (ADR-0053/E43);
enforcement can pin paths read-only per run (ADR-0042); and ADR-0043 already
distinguishes evidence that DEMONSTRATES from evidence that merely CLAIMS.

## Decision

### 1. A first-class `scenario` provider kind

A `scenario` predicate binds one Gherkin Scenario to one committed, replayable
realization of it (its **pin**, decision 2) and delegates execution to an
existing surface provider:

```toml
[[predicate]]
id = "pat__user-can-create-and-download-a-pat"   # the importer's derived id
provider = "scenario"
spec = "docs/specs/pat.feature"
scenario = "User can create and download a PAT"
surface = "browser"            # or "cli"; defaults from the @interface: tag
base_url = "http://localhost:4000"   # surface passthrough config
pin = "docs/specs/pins/pat__user-can-create-and-download-a-pat.pin.json"  # default derived
repin = "auto"                 # auto | manual
inputs = { pat_name = "unique_slug" }   # generator, substituted fresh per run
```

**Truth semantics -- the load-bearing invariant:** the predicate is `:pass` iff
the committed pin validates (decision 2) and REPLAYS green through the
underlying surface provider. No demonstration transcript, agent report, or any
other claim can satisfy it. An inability to replay at all (Playwright missing,
malformed pin schema) is `:error`, never `:fail` (ADR-0002).

It earns first-class by every ADR-0043 test: (a) kazi-native -- the importer,
the specs tier, the enforcement machinery and the harness seam are all kazi's;
(b) extremely common -- "a user can X" is the single most common acceptance
ask, the one the operator states first; (c) richer evidence than a
`custom_script` parse -- a pin state machine, a per-step realization matrix,
and repin diffs.

### 2. The pin: a committed, replayable realization of one Scenario

A pin is a versioned JSON artifact, one per Scenario, named by the importer's
derived id (stable, upsert-safe -- ADR-0021/T13.2), living beside the specs
tier (`docs/specs/pins/`; it follows its `.feature` file through ADR-0050's
archive lifecycle). Its schema (kazi-owned, `pin_version`ed):

- **identity**: `spec` path, `scenario` name, and a content hash of the
  normalized Scenario text -- a Scenario edit makes every stale pin detectable;
- **surface** + **trace**: the executable realization, expressed in EXACTLY the
  existing surface provider's config vocabulary -- `:browser` `steps` +
  `assertions` (T2.2 + the E43 assertion pack) or the `:cli` sub-invocation
  matrix (ADR-0053 §2). Pins are a *compile target onto E43*, not a second
  execution grammar; they inherit `samples`/consecutive-pass and every future
  assertion type for free;
- **step map**: each Given/When/Then line mapped to the trace steps/assertions
  that realize it;
- **inputs**: named placeholders (`{{pat_name}}`) with generator kinds
  (`unique_slug`, `random_email`, ...) the provider substitutes fresh at every
  replay -- so replays are idempotent (no name-already-taken failures) and a
  fixer cannot hardcode a happy path for known test data.

Provider-side validation is deterministic and happens before any replay: the
Scenario hash must be current, the trace must be schema-valid for its surface,
**every `When` must map to >= 1 step and every `Then` to >= 1 assertion** -- a
structurally vacuous pin does not load. This guarantees structural, not
semantic, faithfulness; the residual gap is named honestly in Consequences.

### 3. The demonstrator: a second dispatch role, write-disjoint from the fixer

When a `scenario` predicate fails because the PIN is the blocker (missing or
stale), the loop dispatches a **demonstrator** instead of a fixer: the same
`Kazi.HarnessAdapter` seam and posture as `enrich/2` (ADR-0013 §4 -- a fixed,
versioned, controller-owned prompt per ADR-0055's process-contract discipline;
output validated before acceptance), equipped with whatever browser/CLI
automation the harness already has. Its job: operate the running surface,
accomplish the Scenario literally, and write the pin that encodes how.

The roles are **write-disjoint**, enforced by ADR-0042 `read_only_paths` made
role-scoped (the one genuine extension to existing machinery this ADR asks
for):

- the **demonstrator** may write ONLY pin paths; code, specs, and the goal-file
  are read-only to it;
- the **fixer** keeps its normal write surface but pins and specs are in its
  `read_only_paths` -- the pin is a grader artifact.

Neither role can satisfy the predicate alone: the fixer cannot forge the
grader; the demonstrator cannot patch the app, so if the capability is broken,
its demonstration honestly fails and becomes grounded evidence for the next
fixer dispatch. A freshly minted pin is accepted only if it validates AND
replays green in the same iteration -- pins are born reproducible, so
demonstration-time nondeterminism (the agentic, expensive part) is quarantined
at authoring time and evaluation stays deterministic and cheap. Pins land
through the ordinary ADR-0055 integration contract, so a pin (and every repin
diff) is reviewable in the PR like any other change.

### 4. Failure routing and the repin lifecycle

The provider classifies WHICH artifact blocks the predicate, and the work-list
projection (ADR-0009) routes accordingly -- no `decide/2` special case
(ADR-0055's rule):

- **`unpinned`** (no pin yet) or **`pin_stale`** (Scenario hash mismatch) ->
  demonstrator work: evidence carries the Scenario steps and the pin contract.
- **`replay_red`** (valid pin, red replay) -> if code changed since the pin was
  minted and `repin = "auto"`, one re-demonstration: success means the surface
  drifted while the capability survived -- the new pin lands with its diff as
  evidence (selector rot, finally distinguishable from regression); failure
  means the CAPABILITY is broken -- `:fail` with both the red replay and the
  failed demonstration as evidence, routed to the fixer.
- **Repeated demonstration failure with no intervening code change** -> the run
  goes stuck with a new ADR-0058 cause class (`capability_unreachable`) instead
  of looping demonstrations forever.
- **`repin = "manual"`** gates re-pinning on operator approval for high-stakes
  goals; the default is `auto` because every repin is PR-reviewable anyway
  (decision 3).

Demonstrations are ordinary dispatches under the goal's existing iteration and
token budgets; the economy envelope (ADR-0046/0058) tags spend with the role,
so demonstrator cost and repin churn are observable and learnable like
everything else.

### 5. Importer lowering: an opt-in extension of ADR-0054 decision 3

`kazi spec import` gains an opt-in lowering mode (flag naming finalized in the
epic, per the ADR-0050 precedent): `@interface:web` Scenarios lower to
`scenario` predicates with `surface = "browser"`, `@interface:cli` to
`surface = "cli"`. The DEFAULT lowering is unchanged -- untagged files still
derive `test_runner` predicates byte-identically (ADR-0054's compatibility
promise), which also remains the RIGHT lowering for repos that genuinely
practice BDD and have step definitions. `@interface:api` stays deferred until
an API-flow surface earns promotion (ADR-0053 §3); derived ids and
Feature-grouping (ADR-0020) are untouched.

### 6. Standing goals: pinned scenarios are capability monitors

In a STANDING goal pointed at a deployed `base_url`, pinned scenarios replay as
synthetic capability monitors: a red replay is a detected capability regression
naming the exact failing step, with `samples` for flake discipline. This is the
machine-checkable form of the definition-of-done's "verified live" step --
completing, one level up, the argument ADR-0053 closed with: turn "should work"
into a predicate the loop cannot declare done without.

### 7. Mechanism inventory (what this actually adds)

One provider + one loader validation clause + one registry entry + `kazi schema
scenario` (mirroring `:cve`/`:cli` byte-for-byte in structure); the pin schema
and its validator; role-scoped `read_only_paths` (an extension of ADR-0042's
existing enforcement, not a new system); one work-routing classification in the
provider's evidence; a `download`/file-effect assertion type in the browser
runner (an E43-sized, runner-only addition -- the PAT example needs it).
Everything else -- parsing, tags, derived ids, replay engines, assertion
vocabulary, enforcement, landing, budgets, stuck causes -- is reuse.

## Consequences

- **kazi gets a standard way to verify software behavior at the capability
  level** -- the gap the operator named. The standard is a three-layer
  contract, two layers of which were already frozen: intent as a Gherkin
  Scenario (a real external standard, ADR-0050/0054) -> realization as a pin
  (a replayable DEMONSTRATION in the runner vocabulary, ADR-0043's evidence
  tier made durable) -> verdict as envelope v2 (ADR-0041). "A user can create
  and download a PAT" becomes objectively checkable, and stays checked every
  iteration for the price of a browser journey, not an agent.
- **The Cucumber glue problem is automated and kept honest.** The demonstrator
  authors and repairs the intent->execution join that BDD teams hand-maintain;
  the replay requirement plus write-disjoint roles keep it from being
  hallucinated. Selector rot and capability regression -- indistinguishable in
  every E2E stack today -- produce different verdicts with different evidence.
- **Honest residual risk, named:** the step map guarantees structural
  faithfulness only. A demonstrator could realize a `Then` with a weak-but-
  mapped assertion; replay would then pass green. Mitigations: pins land via
  PR (ADR-0055) so weak assertions are reviewable diffs; `repin = "manual"`
  for high-stakes goals; the demonstrator prompt is controller-owned and
  versioned, so hardening is central; `held_out` (ADR-0042 §6) remains
  orthogonal and available. Semantic-faithfulness checking is future work and
  must NOT be an LLM judgment inside the envelope.
- **A second dispatch role is new operational surface** -- routing, budget
  attribution, a stuck cause. Bounded by reusing the dispatch, enforcement,
  economy, and landing machinery; the epic's first wave should ship the
  provider + pin validation + replay alone (hand-authored pins work day one),
  with the demonstrator role as a second wave.
- **Dependency ordering:** replay delegates to the E43 vocabulary, so E43
  Waves A/B (assertion pack + `:cli`) precede this; the dogfood then extends
  ADR-0053's: kazi's own catalog gains cli scenarios over the RELEASED binary
  ("a user can init -> plan -> approve -> apply a hello goal") and browser
  scenarios over the dashboard -- the release-boundary capability breaks that
  have repeatedly escaped `mix test`, caught one level above where ADR-0053
  catches them.
- The app under test must be reachable at `base_url`/`cmd` -- the author's
  concern, exactly as for `:browser`/`:cli` today. Scenarios that create state
  should either clean up in their own `Then` steps or tolerate accretion in
  the target environment; input generators make replays collision-free but not
  side-effect-free.

## Alternatives rejected

- **LLM-as-judge verdicts** ("an agent tried it and says it works" satisfies
  the predicate). Violates ADR-0002/0009 at the core: judgment never grades.
  Rejected without qualification -- this is the bright line the pin exists to
  hold.
- **Runtime natural-language step resolution** (auto-playwright/ZeroStep-style
  AI selector interpretation at evaluation time). Makes EVALUATION
  nondeterministic and model-priced on every iteration, and a flaky resolver is
  indistinguishable from a broken capability. The pin moves exactly that
  intelligence to authoring time and replays it deterministically thereafter.
- **Require real Cucumber step definitions** (make `test_runner` lowering the
  only path). Serves only repos already practicing BDD, trusts the repo's own
  glue as grader, and hand-maintained glue is the rot this ADR automates. Kept
  as the default lowering where it genuinely fits.
- **Human-recorded traces only** (Playwright codegen et al.). A human
  bottleneck with no drift repair. Still compatible: a hand-authored or
  recorded pin that validates and replays is a perfectly good pin; the
  demonstrator is how pins exist WITHOUT that human.
- **Let the fixer author pins** (one role). The agent that benefits from green
  authors the grader -- the reward-hacking pattern ADR-0042 exists to prevent
  (METR's 43x finding). The write-disjoint split is the point of decision 3.
- **Per-surface kinds** (`:web_scenario`, `:cli_scenario`). One kind with
  `surface` config, mirroring ADR-0053's own rejection of split kinds.
- **A bespoke pin execution DSL.** A second execution grammar would fork the
  E43 vocabulary and double the runner surface; pins deliberately reuse the
  surface providers' config shape verbatim.

## Related

- Extends ADR-0054 decision 3 with an opt-in lowering target (tag vocabulary,
  defaults, and compatibility promise unchanged); no status-line change to
  ADR-0054 needed (extension, not supersession -- the ADR-0053/0043 pattern).
- Compile target and dependency: ADR-0053/E43 (`:browser` assertion pack,
  `:cli` provider, plus one new `download` assertion).
- Reuses ADR-0013's harness-enrichment seam for the demonstrator role and
  ADR-0055's landing contract for pin integration.
- Extends ADR-0042 enforcement to role-scoped `read_only_paths`; `held_out`
  unchanged.
- Realizes ADR-0021's intended-vs-actual at capability level: `I \ A` becomes
  "Scenarios without a green pin."

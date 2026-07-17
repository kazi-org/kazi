# `docs/specs/` — behavior specs (the Gherkin tier, ADR-0050)

This directory is kazi's **behavior-spec tier**: Gherkin `.feature` files that state
*the behavior being built*, in reviewable prose, upstream of the machine check.

It fills the gap between the other doc tiers:

| Tier | Answers | Form |
|------|---------|------|
| `docs/adr/` | **why** a decision was made | prose ADR |
| `docs/plan.md` + `docs/plans/*.md` | **what** work is scheduled | one-line WBS tasks |
| `docs/specs/` (this tier) | **what behavior** is being built | Gherkin `.feature` |
| `goal.toml` predicates | **the machine check** | `[[predicate]]` entries |

The point of the tier: predicates should be **derived from a reviewed behavior
spec**, not hand-typed. You write the Scenarios a human can review, then run
`kazi spec import` to turn each Scenario into a `custom_script` acceptance
predicate — the importer (`Kazi.Reconcile.GherkinImporter`, ADR-0021/T13.2) is
deterministic, so the same spec always yields the same predicates.

Each generated predicate is a **scaffold**, not a runnable check: a `.feature`
says WHAT behavior must hold, never HOW to verify it, so the importer emits a
`custom_script` predicate with a placeholder command that loads but exits
non-zero (honestly RED) until you replace it with the scenario's real check. The
scenario's Given/When/Then steps ride along on the predicate so you know exactly
what to wire. This is deliberate — kazi scaffolds, it does not guess (ADR-0013).

## Naming — "behavior spec", not "spec"

kazi already overloads the word *spec*. To avoid collision, this tier is always
called a **behavior spec**:

- a **behavior spec** is a `.feature` file *here* (this tier, ADR-0050);
- a **goal spec** is a `goal.toml` (ADR-0036);
- an Elixir `@spec` is a typespec.

When you mean this tier, say "behavior spec".

## Files

Each behavior spec is:

- **`<slug>.feature`** (required) — the Gherkin. One `Feature:` per capability,
  one `Scenario:` per behavior. The importer parses a deliberate SUBSET of
  Gherkin — `Feature:` / `Scenario:` / `Scenario Outline:`,
  `Given`/`When`/`Then`/`And`/`But`/`*` steps, and `@tag` lines (see
  [Tags](#tags)). Comments (`#`), `Background:`, and `Examples:` tables are
  skipped for predicate emission (a Scenario is one predicate regardless of its
  Examples rows).
- **`<slug>.md`** (optional) — a paired proposal note: rationale, links to the
  ADR/WBS task, anything the `.feature` cannot carry.

## Tags

The importer reads Cucumber `@tag` lines (T41.1, ADR-0054). The tag **mechanism**
is standard Gherkin — tags sit above a `Feature:` or `Scenario:`, several per
line, and a Feature's tags are inherited by its Scenarios. The **vocabulary**
below is kazi's own documented convention, the same honesty this tier already
applies to its Gherkin subset:

| Tag | Means | Lands on the predicate as |
|-----|-------|---------------------------|
| `@role:<role>` | who the use case is for | `role` |
| `@priority:P0`..`P3` | how important it is | `priority` |
| `@interface:web\|api\|cli\|sdk\|grpc\|background\|ws` | how it is exercised | `interface` |

```gherkin
@role:shopper
Feature: Storefront

  @interface:web @priority:P0
  Scenario: A shopper checks out a basket
    Given a basket with two items
    Then the order is confirmed
```

Like `steps`, these are **self-describing metadata**: no provider consumes them,
they are there so the predicate carries its own "what and for whom".

Three properties worth relying on:

- **Tags are additive.** An untagged `.feature` derives exactly the predicates it
  always did, byte-for-byte. Every spec written before tags existed still imports
  unchanged.
- **An unknown tag is ignored, never an error.** Your house tags (`@smoke`,
  `@wip`, `@owner:growth`) and malformed values (`@priority:P9`) pass through
  harmlessly — so a `.feature` file you already maintain for Cucumber imports as-is.
- **A Scenario's own tag wins** over one inherited from its Feature.

### What `@interface` derives

`@interface:web` derives a `browser` predicate and `@interface:api` an
`http_probe` — but only when you tell the importer *where* to probe. kazi never
invents a URL (ADR-0013: kazi scaffolds, it does not guess), and a live predicate
without one will not even load (ADR-0058). Without a base URL, the tag records its
metadata and the `custom_script` scaffold stands. The other interfaces (`cli`,
`sdk`, `grpc`, `background`, `ws`) have no provider that could check them from a
`.feature` alone, so they record metadata and keep the scaffold.

A derived live predicate is a **scaffold too, and honestly RED** — it ships with a
placeholder expectation you replace. This matters more than it might sound: a
`browser` predicate with no assertions passes on any page that renders, and an
`http_probe` with no expectation passes on any completed request, so a derived
probe that just pointed at your URL would report every use case green while
verifying nothing.

## When to use a behavior spec (vs. a plain WBS line + hand predicate)

Use a behavior spec when a capability has **several distinct behaviors** worth
reviewing as a set before any predicate exists — a sign-up flow, an import verb,
a lifecycle with multiple terminal states. The Gherkin is the review artifact and
the predicate set falls out of it.

Skip it for a **single, obvious** acceptance (one `custom_script` or `http_probe`
check): a one-line WBS task plus a hand-written predicate is less ceremony and
just as clear. The tier is optional — a plan task references its spec via an
optional `spec:` field (T40.3) only when it has one.

## Workflow

```
# 1. Write the behavior spec.
$EDITOR docs/specs/my-capability.feature

# 2. Derive predicates into a goal-file (creates it, or upserts into an existing one).
kazi spec import docs/specs/my-capability.feature --into priv/examples/my-capability.goal.toml

# 3. Review the generated [[predicate]] blocks, add any LIVE predicate by hand.
$EDITOR priv/examples/my-capability.goal.toml

# 4. Run it.
kazi apply priv/examples/my-capability.goal.toml --workspace .
```

Re-running step 2 after editing the `.feature` is an **upsert**: the importer
derives each predicate's id from `Feature + Scenario`, so unchanged Scenarios
keep their predicate, edited ones are replaced in place, and a hand-added live
predicate in the goal-file survives the re-import untouched.

`kazi spec import --json` emits `{ "ok": true, "into": "...", "upserted": [ids], ... }`
so an orchestrator can drive it.

## Lifecycle

A behavior spec archives with its epic (ADR-0036 L1, T40.4): when an epic's WBS
block is archived, any `.feature`/`.md` files its tasks reference via `spec:`
move verbatim to `docs/specs/archive/` alongside the epic file — the same
lossless, git-diff-able move as the epic body itself.

## See also

- **ADR-0050** — the decision to add this tier.
- **ADR-0021 / T13.2** — `Kazi.Reconcile.GherkinImporter`, the deterministic
  parser this tier is wired over.
- **`example.feature`** — a worked example (the `spec import` verb's own
  acceptance, dogfooding the tier from day one).

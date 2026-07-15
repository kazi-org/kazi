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
  Gherkin — `Feature:` / `Scenario:` / `Scenario Outline:` and
  `Given`/`When`/`Then`/`And`/`But`/`*` steps. Comments (`#`), tags (`@tag`),
  `Background:`, and `Examples:` tables are skipped for predicate emission (a
  Scenario is one predicate regardless of its Examples rows).
- **`<slug>.md`** (optional) — a paired proposal note: rationale, links to the
  ADR/WBS task, anything the `.feature` cannot carry.

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

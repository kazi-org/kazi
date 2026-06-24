# ADR 0020: Hierarchical predicate grouping via a declared group taxonomy

## Status
Accepted

## Date
2026-06-23

## Context

A `Kazi.Goal` holds a FLAT list of `Kazi.Predicate`s. That is fine for a small
goal, but a goal that represents a whole product's desired state has hundreds of
predicates with no way to organize them. The motivating exercise (the sirerun
dogfood, `docs/devlog.md` 2026-06-23) drove this: sire's `capabilities.json` is
317 capabilities across 9 pillars, each capability carrying machine-checkable
evidence. To answer "where is sire -- what is intended, built, pending" you need
the predicates organized as **pillar -> domain -> capability**, and you need to
push that hierarchy to a visualization tool (Obsidian) showing each node's state.

Three forces shape the decision:

1. **Hierarchy.** Predicates need an optional grouping so a large goal reads as a
   tree, and so a goal can be sliced by group for reporting and export.
2. **Per-group reconciliation / budgets.** The operator wants per-pillar budgets
   and convergence, not one undifferentiated loop over hundreds of predicates --
   without paying for a separate `Goal` per pillar.
3. **Robustness to text drift.** If the group is free text, inconsistent spelling
   ("Identity & Access" vs "Identity and Access", "Sign up" vs "Register")
   silently FRAGMENTS the hierarchy -- the single most likely failure mode of a
   string-keyed grouping.

## Decision

Add an optional **group** to predicates that REFERENCES a **declared group
taxonomy**, validated at load. Declare once, reference by id, validate at parse
time -- so text drift cannot silently fragment the tree.

1. **A declared taxonomy.** The goal-file gains a `[[group]]` array; each entry is
   `{id, name, parent?, budget?}`:
   - `id` -- a stable slug (`identity-access`), the ONLY thing predicates
     reference. Lower-cased/hyphenated, so `&`/case/whitespace variants normalize
     to one canonical id.
   - `name` -- the human display label (`"Identity & Access"`), declared exactly
     once.
   - `parent` -- an optional parent group id; the parent chain reconstructs the
     tree to arbitrary depth (pillar -> domain -> capability) without nesting in
     the file.
   - `budget` -- an optional **cap** (iterations / cost). A group's effective
     budget is DERIVED, not stored: it is the SUM of its descendants' budgets, so
     a parent total is never hand-maintained and can never drift from its
     children. Declare budgets only where the work lives (leaves); a `budget`
     declared on a non-leaf group acts as a ceiling that can only TIGHTEN the
     rollup (`effective = min(cap, sum-of-descendants)`), never inflate it. So a
     parent budget is either absent (= the sum) or a deliberate cap -- nothing to
     keep in sync, the same "derive what you can, store only the irreducible"
     principle as the id-referenced taxonomy itself.

2. **Predicates reference a group by id.** `Kazi.Predicate` gains an optional
   `group :: String.t() | nil` -- a declared group id, NOT a free-text path. Nil =
   ungrouped (current behavior; fully backward-compatible).

3. **The loader validates the taxonomy (the drift guard).**
   `Kazi.Goal.Loader.from_map/1` rejects, at parse time:
   - a predicate whose `group` is not a declared id (catches the typo immediately,
     rather than fragmenting silently);
   - a group whose `parent` is not declared;
   - a cycle in the parent chain.
   A separate `kazi lint` fuzzy-warns on near-duplicate group NAMES as a second
   net (advisory, not a hard error).

4. **Per-group budgets/reconciliation ride on existing partitioning, with DERIVED
   budgets.** A group is a partition key. The loop scopes convergence to a group's
   predicate partition (the graph partitioning of ADR-0006) and reports per-group
   status. A group's budget is the SUM of its descendants' budgets (derived, not
   stored -- see decision 1), tightened by an explicit cap where one is declared;
   so per-pillar budgets aggregate automatically and a parent total never needs
   maintaining. This delivers the operator's "per-pillar budgets/reconciliation"
   WITHOUT a separate `Goal` per pillar -- confirming the operator's hunch (both
   that grouping suffices, and that the budget should be a calculated rollup).
   Composable
   sub-goals (a `Goal` per pillar, ADR-0011-style independent lifecycle) remain a
   future option only if independent approval/lifecycle per group is ever needed.

5. **An importer and an exporter use the taxonomy.**
   - The desired-state importer that populates the groups is a GENERAL one --
     standard specs (OpenAPI/gherkin) + prose docs via the harness -- defined in
     **ADR-0021**, NOT a bespoke `capabilities.json` importer. (An earlier draft of
     this ADR proposed `kazi init --from-capabilities`; that re-introduced the
     bespoke input ADR-0015 withdrew and is corrected by ADR-0021.) Whatever the
     source, importers emit the declared `[[group]]` taxonomy + grouped predicates,
     so a multi-segment source (e.g. pillar -> domain -> capability) is consistent
     by construction.
   - An exporter walks the group tree + predicate verdicts into an Obsidian vault
     (one note per group/predicate, `[[wikilinked]]`, tagged intended/built/
     pending/dead) and/or a Mermaid graph.

## Consequences

- **A large goal becomes legible and sliceable.** Hundreds of predicates organize
  into a validated tree; reporting, budgets, and export all key off the same
  group ids.
- **Text drift is caught at parse time, not discovered in a broken graph.** The
  closed, referenced-by-id vocabulary is the structural fix for the operator's
  stated concern; normalization + a fuzzy lint are belt-and-suspenders.
- **Backward compatible.** `group`/`[[group]]` are optional; an existing goal with
  no groups behaves exactly as today. The new `Predicate.group` field is appended
  additively (like `harness`/`standing` before it).
- **Per-pillar reconciliation without sub-goal weight.** Per-group budgets reuse
  the existing partitioning; no new goal-lifecycle machinery.
- **Code-level evidence predicates are weak on their own.** The dogfood verified
  evidence EXISTENCE, not behavior; the manifest's 178 `with_drift` rows need LIVE
  predicates (`http_probe`/`browser` against a running sire) to adjudicate. The
  grouping is what makes that scale legible; the live predicates are the deeper
  follow-on (future work, needs a running instance + test credentials).
- **A small loader/evaluator surface to touch.** The loader gains taxonomy
  parsing + validation; the evaluator/report gain group-awareness; the importer
  and exporter are new but self-contained.

## Alternatives rejected

- **Free-text `group`/path on predicates (no declared taxonomy).** The obvious
  cheap option, rejected for exactly the operator's concern: inconsistent text
  silently fragments the hierarchy, with no parse-time guard.
- **Explicit nested predicate groups in the goal-file (a literal tree of blocks).**
  More structural but verbose and harder to author/diff for a 300-node tree; the
  declare-flat-with-parent-links form reconstructs the same tree with stable ids
  that the importer/exporter can reference.
- **A separate `Goal` per pillar (composable sub-goals) now.** Heaviest; buys
  independent lifecycle/approval per group that the dogfood does not need. Kept as
  a future option; per-group budgets already give the reconciliation behavior.

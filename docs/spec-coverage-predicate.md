# The `spec_coverage` predicate

`spec_coverage` is the **manifest-coverage** gate (T41.3, ADR-0050/ADR-0054): it
fails when a scanned surface element — an exported function, Mix task, or CLI
command — is **referenced by no Scenario** across the product's `.feature`
behavior specs.

Where the `docs_updated` predicate asks "did this *change* ship its docs?",
`spec_coverage` asks the standing question "is the *whole* public surface
documented by a behavior spec?". It is the goal-file-runnable form of the
`Kazi.Reconcile.SpecCoverage` meta-predicate (which was, until this provider,
only a library function usable from tests).

## What it checks

1. **Scan the surface.** `Kazi.Reconcile.SurfaceScanner` inventories the
   workspace's public surface (exported `def`s as `Module.fun/arity`, Mix tasks as
   `mix <task>`).
2. **Read the specs.** The `.feature` files selected by the `features` glob are
   parsed into Scenarios.
3. **Match.** A surface element is **covered** when a Scenario's name or steps
   reference it (by route/path or symbol name — the same approximate,
   reference-like matching `Kazi.Reconcile.Coverage` uses). An element covered by
   no Scenario, and not allow-listed, is **uncovered** — undocumented surface.

Nothing uncovered is a **`:pass`**. Any uncovered element is a **`:fail`** whose
evidence **names each undocumented element** (never merely counts it), so the loop
surfaces "write a Scenario for `GET /secret`" as ordinary failing work. The
provider is read-only — it never edits anything.

A repo with **no matching `.feature` files** yields the whole surface as
uncovered — a real, honest `:fail`. That is exactly the starting state a discovery
goal (`kazi init --discover`) writes a goal to drive down.

`score` is the uncovered count (`direction: lower_better`), so the loop reads
progress as the undocumented surface shrinks. A non-existent workspace is an
`:error` (the scan could not run), never a false `:pass`.

## Config

Introspect every key at runtime with:

```
kazi schema spec_coverage
```

| Key            | Type                    | Default                      | Meaning |
|----------------|-------------------------|------------------------------|---------|
| `features`     | string \| array<string> | `docs/specs/**/*.feature`    | Workspace-relative glob(s) selecting the product's `.feature` specs. A glob matching nothing means zero Scenarios (whole surface uncovered), not an error. |
| `allow_list`   | array<string>           | `[]`                         | Patterns (plain strings or `prefix*` wildcards) for intentional un-documented surface (internal/debug entry points). |
| `source_dirs`  | array<string>           | the scanner's default        | Source directories the surface scan walks. |

## Example

```toml
[[predicate]]
id = "surface-is-documented"
provider = "spec_coverage"
description = "every public surface element is documented by a Scenario"
features = "docs/specs/**/*.feature"
allow_list = ["Kazi.Internal.*"]
```

## Caveats

The surface scan is **approximate by design** (`docs/lore.md` #surface): a static
scan cannot see surface reached by reflection or string dispatch, and the
Scenario-to-element match is a documented string rule, not exact resolution. A
false *positive* (an undocumented element read as covered) is the more harmful
direction, so the matcher keeps Scenario tokens reference-like (a word containing
`/` or `.`) rather than treating every word as a reference. Use `allow_list` for
surface that is intentionally undocumented.

# ADR 0015: init source/output model — registry adapter + goal-set output

## Status
Accepted

## Date
2026-06-22

## Context

ADR-0013 decided that `kazi init` reverse-engineers a starter goal-file by
**deterministic stack detection** (`go.mod` -> `go test ./...`, etc.), scaffolds
live predicates as commented TODOs, and keeps agent enrichment opt-in/off-by-default.
That decision fixed two things implicitly that a second adoption shape now forces us
to make explicit:

1. **init has exactly one input source** — marker files at a repo root.
2. **init emits exactly one goal-file** — a single repo-level baseline guard goal.

A real adoption target breaks both assumptions. The motivating consumer is a product
that already maintains a machine-readable **capability registry**: a hand-built,
code-verified `capabilities.json` (~317 capabilities) plus a partial test-coverage
binding (`coverage.json`). Today its "single source of truth" is split across prose
(`capabilities.md`, `usecases.md`) and that JSON, reconciled by periodic manual agent
fan-outs that go stale the moment code changes. The goal is to let `kazi init` turn
that registry into a kazi goal set so **status is computed by the convergence loop
instead of hand-stamped.**

A capability registry is a *deterministic, structured* input — parsing it is the same
*kind* of pure operation as mapping `go.mod -> go test ./...`. But a multi-capability
registry cannot become one guard goal: it is a *set*. So `kazi init` needs (a) more
than one deterministic input source and (b) a goal-*set* output mode. That is a
genuinely new decision about init's source/output model, distinct from 0013's
stack-detection logic — hence a new ADR refining 0013 rather than an amendment to it
(the repo's convention is one-decision-per-ADR, append-only, forward-linked). This
preserves 0013's determinism boundary; it does not relitigate it.

## Decision

### 1. Pluggable, deterministic `init` sources (no new verb)

`kazi init` stays the single adoption verb (ADR-0013). It grows a second
**deterministic** input source — a **registry adapter** — selected by input, not by a
new subcommand:

- `kazi init <repo-dir>` -> **stack-detection source** (ADR-0013) -> one goal-file.
- `kazi init --registry <file.json>` -> **registry source** -> a goal *set*.

Both sources read through the same injectable introspection seam stack-detection
already uses (`Kazi.Adopt`'s `:file_reader`, consistent with
`Kazi.Context.RepoMapSource`, ADR-0010) — not a separate scanner. Parsing a structured
registry is a pure function over a file read; it never shells out and never reaches
the network.

### 2. Goal-set output: ONE goal-file per capability

When the source is a registry, `init` emits a **goal set** — one goal-file per
capability row — written under an output directory (organised into `--out/<scope>/`
subdirectories when a capability declares a `scope`). Each generated goal-file
round-trips through `Kazi.Goal.Loader` (the same invariant ADR-0013 requires of the
single-file path).

**Why one-goal-per-capability and not a single goal carrying a predicate matrix:** a
kazi *goal* is the unit of convergence, budget, claiming, and reported status; a
*capability* is the unit of "what the product does" and the status we want computed.
Mapping capability <-> goal is what makes status computed *per capability* by the loop —
the entire point of the feature. The rejected alternative (one goal, N predicates)
couples N unrelated capabilities into a single convergence unit: one failing capability
makes the whole goal "stuck," budget is shared across all of them, and per-capability
status is destroyed. A predicate matrix optimises for one file; a goal set optimises for
the thing being modelled. We choose the goal set.

The single-file output stays the default for the greenfield / stack-detection source —
a repo is one convergence unit, so it is one goal.

### 3. Hard boundaries (these are part of the decision, not guidance)

- **Prose registries (`*.md`) are not inputs.** `capabilities.md` / `usecases.md` are
  *views* of the JSON. Parsing prose is interpretation, which reintroduces exactly the
  non-determinism ADR-0013 isolates. `init` consumes the JSON registry and rejects a
  prose path with a clear error. This also bakes "JSON is truth, `.md` is generated"
  into the tool.
- **Source-code predicate inference stays in the opt-in enrichment path** (ADR-0013
  decision 4, off by default). Deriving "which test covers this capability" from source
  is non-deterministic surface-matching; it belongs behind `--enrich` and is used only
  to fill bindings the catalog leaves as *gaps*. Enrichment never overrides a declared
  binding.
- **Live predicates are scaffolded, never guessed** (ADR-0013 decision 3) — each
  generated goal carries a commented `http_probe`/`browser` predicate with `TODO`
  placeholders (URL, expected body) for a human to complete.

### 4. Minimal registry-schema contract (decoupled from any one product)

`init` accepts a small, documented contract so it is not coupled to the motivating
product's exact JSON:

```json
{
  "version": 1,
  "capabilities": [
    {
      "id": "auth.password-reset",
      "name": "User can reset their password",
      "test": { "cmd": "go", "args": ["test", "./auth/...", "-run", "TestPasswordReset"] },
      "scope": "auth"
    }
  ]
}
```

- Required per capability: `id` (non-empty string) and `name` (string).
- `test` (optional): a declared test binding `{cmd, args}` -> a `test_runner` acceptance
  predicate. `tests` (optional array) carries multiple bindings. A capability with **no**
  binding is a *gap*: its acceptance predicate is scaffolded as a commented TODO and is
  filled only by `--enrich`.
- `scope` (optional string): organises output; it never merges capabilities into one
  goal.
- Unknown extra keys are ignored. The motivating product's `capabilities.json` /
  `coverage.json` map onto this contract; `init` reads only the contract fields.

## Consequences

Positive: adopting kazi on a catalogued product becomes `terraform import` for "what
already works" — a registry deterministically becomes a loadable, runnable goal set whose
code predicates derive reliably and whose live predicates are scaffolded TODOs. Status
stops being hand-stamped prose and becomes loop-computed per capability. Reuses the
existing introspection + loader seams, so little new surface. The JSON-is-truth boundary
is enforced mechanically.

Negative: a large registry produces many goal-files (one per capability) — correct for
the model but more files than a single goal. The contract covers the common registry
shape, not every catalog format, so an odd registry needs a thin field mapping to the
contract before `init` reads it. The `--enrich` gap-filling path reintroduces
non-determinism, so it stays opt-in and clearly separated, exactly as in ADR-0013.

Out of scope (a separate, consuming work item): the product-side consolidation that
renders the `.md` views from the JSON and gates drift in CI. This ADR stops at: `kazi
init` can deterministically turn a capability registry into a loadable, runnable goal
set.

## Relationship to other ADRs

- Refines [ADR-0013](0013-adopt-reverse-engineer-goals.md) (init reverse-engineers a
  goal-file by deterministic stack detection) — generalises its single source/single
  output to pluggable sources + a goal-set cardinality, without crossing its
  determinism boundary.
- Builds on [ADR-0010](0010-context-injection-reexploration-mitigation.md) (the
  `RepoMapSource` introspection seam the registry adapter reuses) and
  [ADR-0002](0002-goals-as-predicates.md) (goal = machine-checkable predicate set;
  truth in the controller).

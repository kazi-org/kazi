# The context store (Gist provider)

The **context store** is a budget-fitted memory for *heavy text artifacts* — test
logs, compiler diagnostics, dependency-resolution output, harness stderr,
prior-iteration summaries, verbose `git diff` — and the repeated loop evidence a
reconcile run accumulates. It is a distinct layer from the structural orientation
pack ([ADR-0010](adr/)) and from semantic retrieval ([ADR-0012](adr/)); see
[ADR-0045](adr/0045-context-store-layer-gist-provider.md) for the design and the
named-layer boundary.

| Need | Layer |
|---|---|
| symbol / call / test impact | structural orientation (code-review-graph) |
| embedding recall of prior context | semantic retrieval (off by default) |
| **heavy docs / logs / specs / transcripts under a byte budget** | **context store (this)** |

It is **off by default**: with no store configured, kazi's per-iteration context is
byte-identical to the pre-store path. This page documents the first provider, the
`gist` CLI adapter (`Kazi.ContextStore.GistCLI`).

## The behaviour

`Kazi.ContextStore` is a behaviour with three callbacks:

- `index/3` — store an artifact's content under a stable, SHA-scoped **source
  label** (`Kazi.ContextStore.Labels`), so an edited file keys to a new label and
  the stale content invalidates cleanly.
- `search/3` — return only the budget-fitting, ranked snippets for a query.
- `stats/1` — report the byte accounting (`indexed_bytes` / `returned_bytes` /
  `saved_bytes`).

## The Gist provider

`Kazi.ContextStore.GistCLI` shells to the [`sirerun/gist`](https://github.com/sirerun/gist)
binary — `gist index`, `gist search --budget N`, `gist stats`. Gist chunks content
and returns only budget-fitting, ranked snippets via lexical search; it is a
complement to the structural graph, never a replacement (it has no call graph or
type model).

### Persistence requires `KAZI_GIST_DSN`

> **Gist's default store is in-memory and per-process.** A `gist index` in one
> process is gone by the time a *separate* `gist search` runs.

Indexing on one iteration and searching on the next therefore requires a shared
backend — a PostgreSQL DSN. Set one of (checked in order):

- `KAZI_GIST_DSN` — kazi's own variable (preferred);
- `GIST_DSN` — gist's native variable.

Without a DSN, only a single index-then-search *within one process* is meaningful.
For long-running, multi-agent, or CI use, configure a DSN.

### Graceful degradation

If `gist` is **not on `PATH`** (or the configured `:gist_bin` is missing), every
callback returns `{:error, :gist_not_available}` — the store is *disabled*, never a
crash, and a run on a machine without `gist` is unaffected. This is the
environment-off counterpart to the config-off `Kazi.ContextStore.NoOp` default.

### Provider options

Passed through the store config (`{Kazi.ContextStore.GistCLI, opts}`):

| Option | Meaning |
|---|---|
| `:gist_bin` | the binary (default `"gist"`); a path form is checked directly |
| `:dsn` | PostgreSQL DSN; defaults to `KAZI_GIST_DSN` / `GIST_DSN` |
| `:env` | extra environment forwarded to the subprocess |
| `:cd` | working directory for the `gist` call |
| `:format` | index content format, `"markdown"` (default) or `"plaintext"` |
| `:limit` | `gist search --limit` (default: gist's own default of 5) |
| `:source` | `gist search --source` filter, and the returned snippet's `:source` |
| `:timeout_ms` | kill an overrunning `gist` call (default: no timeout) |

## The `kazi context` command

`kazi context` is a **thin wrapper** over the provider so you learn ONE CLI — the
provider (the `gist` binary) stays independently usable; the wrapper re-derives no
provider logic, it proxies straight through the `Kazi.ContextStore` behaviour
(T35.7, ADR-0045).

```sh
kazi context index <label> <file>                 # index a heavy artifact under a label
kazi context search "<query>" [--budget N]         # budget-fitted, ranked recall
kazi context stats                                 # byte accounting (indexed/returned/saved)
```

Shared flags:

| Flag | Meaning |
|---|---|
| `--provider <name>` | the context-store provider to proxy to. Currently `gist` (the default). |
| `--budget <N>` | `context search` only: cap the result at N bytes. Default: the provider's own default. |
| `--json` | emit a single parseable JSON object on stdout instead of human prose. |

Examples:

```sh
# index a doc, then recall the budget-fitting snippets for a query
kazi context index workspace-docs ./docs/concept.md
kazi context search "session cookie" --budget 4000

# the byte accounting an orchestrator can parse
kazi context stats --json
# => {"command":"context","subcommand":"stats","provider":"gist",
#     "indexed_bytes":1234,"returned_bytes":210,"saved_bytes":1024,...}
```

Under `--json`, the WHOLE of stdout is one object (the same NON-INTERACTIVE,
machine-parseable contract every kazi `--json` command honors); a provider error
(e.g. `gist` not on `PATH`) is a clear JSON error envelope on stdout with a stable
non-zero exit. Without a DSN, only a single index-then-search *within one process*
is meaningful (see [Persistence requires `KAZI_GIST_DSN`](#persistence-requires-kazi_gist_dsn)).

## Status

The provider integration (`Kazi.ContextStore.GistCLI`) and the `kazi context`
wrapper CLI (T35.7) have landed. The opt-in `kazi apply --context-store gist
--context-budget N` loop wiring and the additive `context_store` JSON stats on the
run result land in a later step.

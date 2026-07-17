# The `docs_updated` predicate

`docs_updated` is kazi's **docs-land-with-code** gate (T44.8, ADR-0034): it fails
when a run changes a **user-facing surface** without updating the docs.

ADR-0034 says a user-facing or behavioral change is not done until its docs are
done in the *same* change. `docs_updated` turns that discipline into an
**objective predicate** — the same surface-change heuristic the T29.1
`docs_with_code_guard.sh` CI check uses, ported into a provider a goal-file can
declare.

## What it checks

It examines the committed range `base..HEAD`:

1. **Surface change?** A changed file matching a surface pattern — a CLI
   command/flag (`lib/kazi/cli.ex`, `lib/kazi/cli/`), a predicate provider
   (`lib/kazi/providers/`), a public behaviour (`predicate_provider.ex`,
   `harness_adapter.ex`), or the MCP surface (`lib/kazi/mcp/`). If **none**, the
   gate does not apply and the predicate passes **vacuously** (an internal refactor
   is not a docs violation).
2. **Docs present?** If the same diff also touches `docs/`, `README.md`, or
   `AGENTS.md` → `:pass`.
3. **`[no-docs]` marker?** Otherwise, a commit message on the branch carrying
   `[no-docs] <reason>` is the justified escape hatch → `:pass`, with the reason
   captured in evidence.
4. Missing both → **`:fail`**, naming the surface files that triggered the
   requirement.

A non-git workspace is an `:error` (the scan could not run), never a false `:pass`.

## Config

Introspect every key at runtime with:

```
kazi schema docs_updated
```

| Key                | Type            | Default | Meaning |
|--------------------|-----------------|---------|---------|
| `base`             | string          | merge-base with `origin/main`, else the root commit, else the empty tree | The base ref to diff against. |
| `surface_patterns` | array of string | the six surface paths above | Override the surface-defining path regexes (anchored). |
| `doc_patterns`     | array of string | `docs/`, `README.md`, `AGENTS.md` | Override the paths that count as a docs update. |

## Example

```toml
id = "docs-updated-gate"
name = "Docs land with the code"

[[predicate]]
id = "docs-updated"
provider = "docs_updated"
description = "a user-facing surface change ships with a docs update or a justified [no-docs] marker"
```

See `priv/examples/docs_updated.toml`. The convergence gate is unchanged: a
`docs_updated` predicate contributes only its `:pass`.

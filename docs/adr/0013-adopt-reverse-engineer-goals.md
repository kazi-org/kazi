# ADR 0013: Adopting kazi on an existing project (reverse-engineer a goal-file)

## Status
Accepted

## Date
2026-06-22

## Context

Writing the first goal-file is the main barrier to adopting kazi on an existing
codebase. Authoring forward from a prose idea already exists (`Kazi.Authoring`,
T3.5, ADR-0011). What is missing is the reverse: point kazi at a repo that already
works and have it emit a starter goal-file that captures the project's current
checkable surface — the equivalent of `terraform import` or `tsc --init`.

Two distinct goal shapes are wanted, and only the first is mechanically derivable:

- a **baseline / guard goal** ("do not regress what already works") — the detected
  test command plus guard invariants (coverage ratchet, test-count floor). This is
  derivable by static inspection of the repo.
- a **feature goal** ("build something new") — already covered by `kazi propose`.

The risk is over-generation: emitting noisy or wrong predicates erodes trust. And
**live** predicates (the deployed URL, what "healthy" means in production) cannot be
inferred from source — only a human knows them.

## Decision

1. **`kazi init <path>` (a.k.a. adopt) generates a starter goal-file by DETERMINISTIC
   stack detection.** Marker files map to a test-runner predicate: `go.mod` →
   `go test ./...`; `mix.exs` → `mix test`; `package.json` → its `test` script;
   `pyproject.toml`/`setup.cfg` → `pytest`. Detection is pure and hermetically
   testable against fixture repos; it reuses the repo-introspection seam from
   `Kazi.Context.RepoMapSource` (ADR-0010) rather than a new scanner.

2. **Guards are derived conservatively.** When a coverage tool is detectable, emit a
   coverage-ratchet guard; otherwise emit only a test-count/`tests-pass` baseline.
   When in doubt, emit fewer predicates — a small correct goal beats a large noisy one.

3. **Live predicates are SCAFFOLDED, never guessed.** The generated goal-file includes
   a commented `http_probe`/`browser` predicate with `TODO` placeholders (URL,
   expected body) for the human to fill in. The writer round-trips through
   `Kazi.Goal.Loader`, so a generated file is always loadable.

4. **Optional harness ENRICHMENT, off by default.** With an explicit flag, kazi may
   drive the harness to propose live/browser predicates from discovered endpoints,
   behind the same injectable harness seam used elsewhere (hermetic via a stub in
   tests). Deterministic detection is the default; the agent only enriches on request.

## Consequences

Positive: the adoption barrier drops from "learn the goal-file schema and write one"
to "run `kazi init`, fill in the live URL, approve." Code predicates derive reliably
and deterministically; the result is a real regression harness on day one. Reuses
existing introspection, so little new surface.

Negative: the generated goal is only a starting point — live predicates always need
human completion, and stack detection covers the common cases (Go/Elixir/Node/Python)
but not every build system. The optional harness enrichment reintroduces
non-determinism, so it is opt-in and clearly separated from the deterministic path.

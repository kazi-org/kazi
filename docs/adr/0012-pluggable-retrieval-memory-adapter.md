# ADR 0012: Pluggable semantic-retrieval memory adapter (T4.9)

## Status
Accepted

## Date
2026-06-22

## Context

ADR-0005 split kazi's data layer and explicitly deferred "a later pluggable memory
adapter" — a semantic-retrieval (RAG) layer that, for a failing predicate, fetches
the top-k most relevant snippets from the target codebase and feeds them into the
harness prompt. ADR-0010 (context injection) added deterministic blast-radius
orientation (`Kazi.Context`) but deliberately stopped short of similarity-based
retrieval, because retrieval introduces a non-deterministic, dependency-heavy
surface (an embedding model + an index) that the rest of the loop does not have.

T4.9 builds that adapter. The risk to manage: retrieval must NOT silently change
the default behaviour of the loop. The deterministic orientation pack (ADR-0010)
and the thin evidence projection (ADR-0009) are the contract; retrieval is an
optional augmentation, not a replacement. It must also stay hermetically testable
even though its real backend (graphify embeddings) is an external, heavyweight tool.

## Decision

1. **A `Kazi.Retrieval` behaviour, OFF by default.** Define a behaviour
   `retrieve(failing, workspace, opts) :: [snippet]`. The default resolution is a
   no-op (returns `[]`), so the default `build_prompt` output is byte-identical to
   today's. Retrieval is enabled only by explicit per-goal config / opts.

2. **Retrieval augments the prompt as a clearly-delimited optional section.** When
   enabled, the top-k snippets are injected into `build_prompt/3` as a dedicated,
   labelled section AFTER the deterministic orientation prefix (ADR-0010) and the
   failing-evidence body (ADR-0009) — never replacing either. The core loop, the
   budget, and the orientation pack are unchanged.

3. **The real backend is graphify embeddings, behind the seam and
   integration-gated.** The graphify-embeddings backend embeds the target and does
   a similarity search for the failing predicate's evidence terms. Because graphify
   is an external tool, its conformance test is tagged and EXCLUDED by default
   (like the NATS lease integration test, ADR-0004/T3.1b), so the default
   `mix test` stays hermetic. A stub retriever drives all default-path tests.

4. **Reuse existing seams.** Retrieval mirrors the `Kazi.Context.GraphSource`
   injectable-behaviour pattern and may reuse the SHA-keyed cache (T4.6) to avoid
   re-embedding an unchanged target.

## Consequences

Positive: kazi gains optional similarity-based recall for cases where deterministic
blast-radius orientation under-covers, without touching the default deterministic
path; hermetic by default; the heavyweight embedding dependency is isolated behind
a seam and an integration tag.

Negative: a second context source adds configuration surface and a place where two
mechanisms (orientation pack vs retrieval) could overlap or disagree; enabling
retrieval reintroduces non-determinism into the prompt for that goal (accepted,
because it is opt-in and additive). The real backend depends on external graphify
tooling that CI does not run, so its backend is only ever exercised by an
explicitly-included integration test.

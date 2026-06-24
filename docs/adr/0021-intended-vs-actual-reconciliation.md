# ADR 0021: Intended-vs-actual reconciliation -- import intent from standard specs + prose; detect dead code via a surface-coverage meta-predicate

## Status
Accepted

## Date
2026-06-23

## Context

kazi's purpose, stated plainly: **correct software with no dead code.**
Correctness is a two-way containment between the **intended set I** (what should
be true) and the **actual surface A** (what the code exposes):

- `I \ A` = **missing / pending** -- drive the code to satisfy it (kazi's core
  convergence loop).
- `A \ I` = **dead code / undocumented surface** -- the other half, which kazi did
  not address.

Neither a code-import nor a doc-import ALONE yields this; the value is the **diff**,
and producing it requires knowing both sets. `kazi init` (ADR-0013) reverse-
engineers from CODE -- it mirrors A, so it can express a regression guard but can
never state intent, nor flag missing/dead. The intended set must come from
elsewhere.

ADR-0015 withdrew a bespoke `capabilities.json` importer ("a bespoke artifact of
one internal product... an audience of one") and deferred a GENERAL importer to
standard formats "as its own ADR" (UC-025). A same-session draft of ADR-0020 then
re-introduced exactly that bespoke importer (`kazi init --from-capabilities`) --
this ADR corrects that and is the deferred general decision, plus the dead-code
half ADR-0015 did not consider. (Observed: sirerun's own `capabilities.json` IS an
I-vs-A diff -- 249 documented UCs, 68 undocumented-discovered, 178 with-drift --
which is the artifact kazi should COMPUTE, not ingest. See `docs/devlog.md`
2026-06-23.)

## Decision

1. **Import the intended set I from GENERAL sources, never a bespoke catalog.**
   - **Machine specs, deterministically:** an OpenAPI document -> one `http_probe`
     acceptance predicate per path/operation; Cucumber/gherkin features -> one
     acceptance predicate per scenario (JSON-schema and others later). Pure,
     hermetically testable, reproducible.
   - **Prose docs, via the harness:** ADRs / requirements / design docs are drafted
     into candidate predicates by the coding harness through the EXISTING authoring
     path (`Kazi.Authoring` + the clarify phase, ADR-0011 / ADR-0019), always
     human-reviewed before acceptance. Intent that lives only in prose is captured,
     but the harness PROPOSES and a human APPROVES -- never silently trusted.
   - A `capabilities.json`-style catalog is NOT a first-class input; at most a thin,
     project-local adapter a project may write to emit one of the above. The
     withdrawn bespoke importer (ADR-0015) is not reinstated.

2. **`kazi init` stays the small CODE-side bootstrap** (ADR-0013): seed a baseline
   guard goal so a repo can start in regression mode. It is explicitly NOT the
   desired-state source, and cannot be -- code mirrors actual, not intent.

3. **Detect dead code (`A \ I`) with a surface-coverage META-PREDICATE.** A new
   scanner provider inventories the project's public surface (HTTP routes/handlers,
   exported symbols, CLI commands -- language-specific, reusing the repo-
   introspection seam of ADR-0010). A meta-predicate asserts: **every surface
   element is OWNED by >=1 intended predicate** (matched by route/path/symbol). An
   unowned surface element FAILS the predicate -> it is dead-code / undocumented,
   surfaced like any other failing predicate and reconciled (remove it, or add the
   intended predicate that justifies it). Standing mode (UC-016) keeps "no dead
   code" true over time. The meta-predicate supports an explicit allow-list so
   intentional un-predicated surface (internal/debug) is not false-flagged.

4. **Both directions feed the hierarchical view (ADR-0020).** `I \ A` and `A \ I`
   are predicate verdicts grouped by the declared taxonomy and exported
   (Obsidian/Mermaid) as intended / built / pending / dead.

## Consequences

- kazi addresses BOTH halves of "correct + no dead code" within ONE model --
  everything is a predicate; dead code is a failing coverage predicate, not a
  separate tool, and standing mode holds it true continuously.
- The importer GENERALIZES (any OpenAPI / gherkin project), honoring ADR-0015 -- no
  "audience of one."
- The prose-via-harness path is fuzzy by nature; mitigated by routing through the
  existing human-reviewed authoring flow. The deterministic spec path is the
  trustworthy backbone; prose is additive.
- New surface area: a spec parser (OpenAPI/gherkin), a surface-scanner provider per
  language, and the coverage meta-predicate -- each self-contained behind existing
  seams (providers, the importer, ADR-0010 introspection).
- The surface scanner is necessarily language-specific and APPROXIMATE: reflection
  and string-dispatch are invisible to a static scan (the `docs/lore.md` caveat
  about the graph applies). The allow-list and "warn, don't auto-delete" posture
  keep false positives from eroding trust.

## Alternatives rejected

- **Reinstate the bespoke `capabilities.json` importer.** Re-creates the
  audience-of-one liability (ADR-0015). Rejected; this ADR supersedes that part of
  ADR-0020.
- **Derive intent from code alone (a richer `kazi init`).** Code mirrors actual, so
  missing and dead are structurally invisible to it. Rejected as the intent source;
  kept as the bootstrap guard.
- **A separate `kazi audit` tool for dead code.** Splits the model; a one-shot
  report cannot be HELD true the way a standing predicate can. Rejected in favor of
  the meta-predicate (a thin reporting view over the same data is still fine).

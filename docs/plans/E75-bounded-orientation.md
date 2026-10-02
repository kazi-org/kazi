# E75 -- Scope optional orientation and measure its size

Status (2026-10-01): deferred optional work. E75 is not in the current
implementation milestone and did not block E77. Do not treat the prior
orientation proposal or E77's default-context comparisons as completion or
certification of E75.

fidelity: executable
Acceptance: Optional orientation prioritizes declared task paths, excludes unrelated fixtures, fits its explicit allowance, and never removes mandatory intent.

Context and constraints: [E74](E74-dispatch-contract.md). Reuse ADR-0010,
ADR-0045, ADR-0069, ADR-0086 and the shipped E36 tier mechanisms. Optional
orientation is a search hint, not a file permission boundary.
The original proposal included this work because the missing scope option and
ranking seams were known. It is now deferred; broader retrieval algorithms and
default tuning remain deferred too. No additional graph design or model-based
context selection is planned.

### Wave 4: Scope the existing builder (1 agent)

- [ ] T75.1 Feed task scope into orientation ranking. Owner: pool Est: 90m verifies: [UC-033, UC-065] deps: [T74.3] acc: [The graph and repo-map fixture paths both include declared edit/test files ahead of unrelated deployment fixtures, while an empty scope retains a bounded deterministic fallback.]
  - Scope: `lib/kazi/loop.ex`, `lib/kazi/context.ex`, `lib/kazi/context/repo_map_source.ex`, `test/kazi/context_test.exs`, `test/kazi/loop/orientation_prefix_test.exs`. Thread explicit task paths alongside evidence terms through existing options. Read files may exceed write scope; no write permissions are widened.
  - Paired tests use misleading empty/generic evidence, relevant source and test files, irrelevant fixture sentinels, missing paths, and two identical builds. Test both injected graph and fallback sources. A deliberate removal of task-path ranking must expose the unrelated-content regression. Do not assume filename ordering implies relevance.

### Wave 5: Bound and attribute context (1 agent)

- [ ] T75.2 Account for every controller prompt section and truncate only optional context. Owner: pool Est: 90m verifies: [UC-065] deps: [T75.1] acc: [Dispatch metadata reports actual UTF-8 bytes and separately labelled estimated tokens per section, and optional orientation stays within its configured allowance with complete brief and acceptance requirements.]
  - Scope: `lib/kazi/loop.ex`, `lib/kazi/harness/prompt.ex`, `lib/kazi/context.ex`, `lib/kazi/context/cache.ex`, `test/kazi/loop/orientation_prefix_test.exs`, `test/kazi/harness/prompt_test.exs`, `test/kazi/read_model/orientation_pack_cache_test.exs`.
  - Extend existing context metrics, not a second profiler. Names identify work item, orientation, evidence, and other sections; sum section bytes plus separators equals rendered prompt bytes. UTF-8 bytes are not characters or provider tokens; estimates are never billed usage. Full diagnostics remain in existing evidence artifacts, bounded excerpts retain an artifact reference.
  - Paired tests: multibyte text, zero/tiny allowance, repeated prompt determinism, changed file contents and scope invalidating cached selection, no graph, oversized evidence, and missing optional store. Explicitly distinguish whole controller prompt from unobservable harness system/tool context. Existing default sizes and tier escalation remain unchanged until E77 evidence.

### Wave 6: Validate orientation delivery (1 agent)

- [ ] T75.3 Run orientation tests and installed CLI fixture gate. Owner: pool Est: 60m verifies: [UC-033, UC-065, infrastructure] deps: [T75.2] acc: [A release-candidate installed CLI emits a complete contract and bounded relevant orientation for the misleading-evidence fixture; section accounting reconciles and all scoped checks pass.]
  - Run `MIX_ENV=test TEST_SERVER=false mix test test/kazi/context_test.exs test/kazi/loop/orientation_prefix_test.exs test/kazi/read_model/orientation_pack_cache_test.exs test/kazi/harness/prompt_test.exs test/kazi/cli/dispatch_contract_test.exs`; `mix format --check-formatted`; `git diff --check`.
  - Extend the public-boundary fixture from T74.2, retaining fake harness/no paid API. Follow T74.3 isolated install and authorized distributed-release verification. Record expected-red mutation, test counts, bytes, and unknown provider-token attribution. No reduction claim from section bytes alone.

## Progress Log

2026 09 06: Scoped E75 to existing context machinery; default tuning deferred to E77.

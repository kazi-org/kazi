# E76 -- Reconcile usage and distinguish estimated from provider cost

Final status (2026-10-01): E76 source and downloaded Kazi v1.297.0 verification
are complete; all 16 consolidated offline scenarios pass, including persisted
and public provenance. The final artifact record is authoritative. This
establishes source/release behavior, not paid-model certification or complete
provider-receipt coverage in E77.

fidelity: executable
Acceptance: Usage conserves tokens across models and attempts; unknown cost stays unknown; an estimate is never labelled actual spend. E77 receipt coverage remains incomplete; missing cost stays unknown.

Context and constraints: [E74](E74-dispatch-contract.md). Reuse ADR-0046,
ADR-0058, ADR-0069, `Kazi.Harness.Usage`, and existing economy history/KPIs.
No required provider network dependency and no pricing constants inferred from
this one pilot. The $2 stop was imposed by the experiment wrapper: parsing
`total_cost_usd` in core and configuring a wrapper admission limit are distinct.

### Delivered parser correction

T76.1 and T74.1 were independent implementation slices and were scheduled in
parallel. This records the completed schedule, not current dispatch guidance.

- [x] T76.1 Select complete per-model usage without overlapping totals. Owner: pool Est: 90m verifies: [UC-064] deps: [] acc: [A synthetic Claude envelope whose modelUsage totals 1352533 and top-level usage totals 1277629 reports 1352533 once, while missing and malformed fields preserve honest fidelity.]  Done: 2026-09-07 (final downloaded-artifact gate, Kazi v1.297.0)
  - Scope: `lib/kazi/harness/profiles/claude.ex`, `lib/kazi/harness/usage.ex`, `test/kazi/harness/claude_adapter_test.exs`, `test/kazi/harness/usage_test.exs`.
  - Select `modelUsage` as a whole when its entries are valid; otherwise use the valid top-level envelope with explicit source/fidelity, or unknown when neither is usable. Never sum both shapes or silently zero-fill malformed/partial model entries. Preserve existing top-level-only harness compatibility.
  - Paired tests: two models, contradictory shapes, empty map, negative/non-numeric fields, partially missing splits, no usage, cache writes/reads, reasoning as a subset of completion. Assert conservation: fresh + cache read + cache write + output equals total; reasoning is not added a second time. Reverting source selection must fail the 1352533 assertion.

### Wave B: Propagate trustworthy provenance (1 agent)

- [x] T76.2 Preserve usage and cost provenance through terminal and persisted economics. Owner: pool Est: 90m verifies: [UC-064] deps: [T76.1] acc: [Two dispatch attempts including a failed attempt contribute once to persisted and terminal token totals; unsubstantiated reported cost is distinguishable from actual spend and missing cost remains unknown.]  Done: 2026-09-07 (final downloaded-artifact gate, Kazi v1.297.0)
  - Scope: `lib/kazi/loop.ex`, `lib/kazi/economy/kpis.ex`, `lib/kazi/economy/history.ex`, `lib/kazi/read_model/run.ex`, `lib/kazi/read_model/iteration.ex`, `test/kazi/loop/iteration_counters_test.exs`, `test/kazi/economy/kpis_test.exs`, `test/kazi/economy/history_test.exs`, `docs/economy.md`.
  - Trace existing adapter-result to dispatch log to read-model fold before editing. Extend the existing optional envelope; retain raw reported cost as reported/estimated until substantiated. Do not repurpose existing fields incompatibly: document additions, missing values, currency, source, and coverage. Review ADR-0046 for any changed budget interpretation.
  - Paired tests: retry, failed dispatch with usage, no terminal usage, duplicated terminal persistence, two iterations without new dispatch, missing receipts. Provider receipt cost must not be added to the estimate for the same attempt. Preserve historical rows and schema_version 2 for additive fields.

### Wave C: Expose provenance to consumers (1 agent)

- [x] T76.3 Expose cost basis and usage source through JSON consumers. Owner: pool Est: 90m verifies: [UC-033, UC-064] deps: [T76.2] acc: [apply/status/economy JSON labels a synthetic $2.017401 harness estimate as unverified reported cost, never actual provider spend, while preserving missing cost as unknown.]  Done: 2026-09-07 (final downloaded-artifact gate, Kazi v1.297.0)
  - Scope: `lib/kazi/cli.ex`, `lib/kazi/cli/usage.ex`, `test/kazi/cli/usage_test.exs`, `test/kazi/cli_economy_test.exs`, `docs/economy.md`. Wire the T76.2 persisted envelope into actual terminal/status/history consumers; do not leave an unused serializer. Keep schema-version-2 compatibility through additive provenance fields and existing schema tests.
  - Paired tests use contradictory top-level/model usage, estimate-only cost, no cost, historical rows without provenance, and mixed-fidelity groups. Actual provider cost is unknown until supported by receipts; the $0.035362955 pilot receipt total is evidence, not a price constant or a field synthesized by this task.
  - Preserve configured budget enforcement and expose its estimate basis. Explain estimated admission limits versus settled spend; receipt lag cannot support a hard real-time dollar guarantee. Authenticated lookup/import and generation-ID association need a production ingress design and remain E77 planning work. No provider network call is introduced here.

### Wave D: Verify the JSON consumer contract (1 agent)

- [x] T76.4 Validate accounting through the installed CLI and compatibility fixtures. Owner: pool Est: 60m verifies: [UC-033, UC-064, infrastructure] deps: [T76.3] acc: [Installed apply/status/economy JSON preserves exact fixture totals and provenance across retry and read-model reload, and offline runs finish without any provider lookup.]  Done: 2026-09-07 (final downloaded-artifact gate, Kazi v1.297.0)
  - Scope: `test/kazi/cli_economy_test.exs`, `test/kazi/harness/claude_adapter_budget_test.exs`, `test/kazi/harness/claude_economy_flags_test.exs`, `docs/economy.md`. Exercise actual CLI/fake-harness boundaries, not only the receipt fold. Assert the native profile's actual argv separately from any wrapper-estimated budget behavior.
  - Run `MIX_ENV=test TEST_SERVER=false mix test test/kazi/harness/claude_adapter_test.exs test/kazi/harness/usage_test.exs test/kazi/harness/claude_adapter_budget_test.exs test/kazi/harness/claude_economy_flags_test.exs test/kazi/loop/iteration_counters_test.exs test/kazi/economy/kpis_test.exs test/kazi/economy/history_test.exs test/kazi/cli/usage_test.exs test/kazi/cli_economy_test.exs`; `mix format --check-formatted`; `git diff --check`.
  - Follow T74.3 isolated candidate installation then authorized distributed-release smoke; report executed counts and genuine-red accounting mutation. All API data here is synthetic, no paid model or real provider request needed.

## Final artifact evidence

Source implementation merged in PR #1846 (`d568b2c6`), with 5,063 CI cases
passing. Source and installed fixtures verified exact retry totals and persisted
provenance; mutation controls rejected dropped and duplicated provenance.

2026 09 07: Downloaded v1.297.0 native macOS arm64 binary passed all 16 offline scenarios (schema version 2), including exact retry totals and persisted/public provenance. Release source: 0b7c7f916f9c883e1c336c440b539c92667861e9. Artifact SHA-256: 9c2bdc135dad2ed09e781b4978448b3a5b3d3fd5cd5c940b7d1c2b32dd610dd7. Active installation unchanged; no provider requests. T76.4 complete.

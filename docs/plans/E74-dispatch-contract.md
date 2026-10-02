# E74 -- Preserve the declared task at the harness boundary

Final status (2026-10-01): E74 source/public/installed contract is complete in
Kazi v1.296.1 and v1.297.0; v1.297.0 passed the consolidated 16-scenario
downloaded-artifact suite. The dated verified-delivery record is authoritative.
This is source/release verification, not paid-model certification.

fidelity: executable
Acceptance: A real apply dispatch contains the authored task brief, every acceptance requirement, and declared read/write scope; orientation cannot evict them.

## Delivered boundary

A dispatched worker receives the complete declared task, predicate descriptions,
acceptance commands and declared paths, including descriptions whose predicates
already pass. Optional orientation must not replace or truncate this contract;
unsupported size fails explicitly before dispatch.

The completed implementation repaired a real omission observed in the original
pilot. E76 separately repaired usage provenance. E75 orientation tuning remains
deferred and is not part of this delivery. E77's later comparison established
no general productivity gain; see its [report](../e77-evaluation-2026-09-08.md).

These checked tasks and the T74.1 contract describe delivered behavior. New work
follows the [current roadmap](../roadmap.md); no dated trial approval or model
restriction in the original proposal applies to a new evaluation.

### Wave 1: Preserve intent (1 agent)

- [x] T74.1 Project the declared task into the stable work item. Owner: pool Est: 90m verifies: [UC-033] deps: [] acc: [A captured dispatch contains the sentinel first-predicate brief, all goal predicate descriptions and acceptance commands, and distinct declared read/write paths even when that first predicate already passes.]  Done: 2026-09-07 (final installed-artifact gate, Kazi v1.296.1)
  - Scope: `lib/kazi/loop.ex`, `lib/kazi/harness/prompt.ex`, new `test/kazi/loop/task_brief_prompt_test.exs`. Read `Kazi.Loop.dispatch_prompt_parts/2`, `failing_slice/1`, and existing goal/predicate structs; reuse their data, no new authoring schema.
  - Preserve full goal acceptance and guards as requirements; separately identify the currently failing IDs and bounded evidence. Render deterministic order. Do not mistake `scope.paths` for permission to write; empty descriptions remain honest, IDs remain present. Optional orientation budgets cannot truncate the task contract. Redact via the existing egress redactor.
  - Paired tests capture the adapter's actual prompt over two iterations; first predicate passes on the second, brief remains. Sentinel requirements disappear and test fails if the old ID-only projection is restored. Existing process-contract/tier-zero behaviors remain intact.

### Wave 2: Verify the public route (1 agent)

- [x] T74.2 Prove plan-to-apply intent survives the public boundary. Owner: pool Est: 90m verifies: [UC-033] deps: [T74.1] acc: [A caller-drafted approved proposal applied through the JSON CLI reaches a fake executable harness with its exact brief, test path, and guard requirements, without any model API call.]  Done: 2026-09-07 (final installed-artifact gate, Kazi v1.296.1)
  - Scope: new `test/kazi/cli/dispatch_contract_test.exs`, new `test/support/dispatch_contract_harness.ex`, `docs/orchestrator-recipe.md`. Exercise real plan/approve/apply in temporary repos and private read-model state; use the existing test CLI capture helpers rather than mock private rendering functions.
  - Repeat through a direct goal-file as well as an approved proposal. Paired negative cases: omit a description, pass the first predicate, use tier zero, and exceed the orientation allowance. Test expected presence/absence explicitly; no substring snapshot that only checks IDs. Document the now-enforced intent boundary and its protected size independently of optional context.

### Wave 3: Release gate (1 agent)

- [x] T74.3 Validate and verify the installed dispatch contract. Owner: pool Est: 60m verifies: [UC-033, infrastructure] deps: [T74.2] acc: [The release-candidate installed CLI reproduces T74.2's contract using a fake harness and emits schema-version-2 JSON; scoped tests and formatter pass.]  Done: 2026-09-07 (final installed-artifact gate, Kazi v1.296.1)
  - Run `MIX_ENV=test TEST_SERVER=false mix test test/kazi/loop/task_brief_prompt_test.exs test/kazi/loop/process_contract_prompt_test.exs test/kazi/loop/orientation_prefix_test.exs test/kazi/cli/dispatch_contract_test.exs test/kazi/harness/prompt_test.exs`; `mix format --check-formatted`; `git diff --check`.
  - Build/install the candidate into an isolated prefix using the repository release procedure, never replace the operator's active binary. After normal release authorization, repeat the fake-harness smoke with the distributed installed version. Record version, command, executed counts, and predicted genuine-red output. Do not claim public release validation before that step occurs. No HTTP deployment exists for this local CLI capability.

## Delivered scope and maintenance

The checked tasks above are a delivery record, not a new dispatch queue.
T74.1 and T76.1 contracts remain reference material for the shipped boundaries.
E75 is deferred and contributes no implementation dependency. Source/release
verification does not imply paid-model certification. Mandatory intent must
remain complete or fail explicitly before dispatch.

## Verification record

### Verified delivery — 2026-09-07

PR #1844 merged as `3b3eec5e2469a8f6b50224e9a1daebd73222b13b`; independent review clear, CI executed 5,047 cases (234 doctests and 4,813 tests), with 124 excluded. Eight public-boundary contract cases cover file/proposal, tier 0/1, and long/absent brief. Four proposal cases failed before the scope/description preservation fix. The freshly downloaded v1.296.1 macOS arm64 artifact passed all 12 offline release scenarios, including four two-launch dispatch-contract cases; schema version 2. SHA-256: `bebf9516685bbb551e49d47b84c5c714f0f8ef2ecb6d10159c3b46ee5bfd9df9`. No active installation changed.

# E74 -- Preserve the declared task at the harness boundary

Final status (2026-10-01): E74 source/public/installed contract is complete in
Kazi v1.296.1 and v1.297.0; v1.297.0 passed the consolidated 16-scenario
downloaded-artifact suite. The earlier pending-row notes below are historical
and superseded by the dated verified-delivery record. This is source/release
verification, not paid-model certification.

fidelity: executable
Acceptance: A real apply dispatch contains the authored task brief, every acceptance requirement, and declared read/write scope; orientation cannot evict them.

## Context

Historical status amendment (2026 09 07; superseded by final verification
above): the core complete-contract fix merged in #1839, including
held-out/quarantine exclusions. The later [PR #1844](https://github.com/kazi-org/kazi/pull/1844)
and [consolidated PR #1848](https://github.com/kazi-org/kazi/pull/1848) record
public/installed and downloaded-release verification. No general productivity
gain was established in the subsequent study.

The objective is lower total tokens, provider dollars, and elapsed time per
accepted software change without weaker correctness or maintainability. This is
an engineering plan, not authorization to execute model calls or change defaults.
Future paid trials use only OpenRouter `z-ai/glm-5.3-flash`, with isolated CLI
configuration and credentials; no Anthropic credentials or model escalation.

A local one-issue component trial stopped stuck after 790.62 seconds and did not
produce an accepted change. Its actual 18,632-byte dispatch omitted the task brief
and test path; 15,998 bytes were orientation. Provider receipts reported 1,352,533
tokens and $0.035362955; core reported 1,277,629 tokens. The experiment wrapper,
not demonstrated native Kazi budget forwarding, imposed a $2 Claude-estimated
cap that tripped at $2.017401. These are separate prompt, parsing, and wrapper
configuration findings. The trial modified integration/process settings and did
not measure the complete outer planning, review, and landing workflow.

For comparison, the previous packet arm accepted the change using 825,846 tokens,
$0.026398740, and 899.90 seconds. All Go attempts including failure and review
repair used 203,745 tokens, $0.007821440, and 253.49 seconds of run time; its
first-attempt-to-verified-repair interval was 583.70 seconds. Prototype engineering
and coordinator usage were excluded. Bundled changes and one repeatedly studied
issue cannot establish general savings or a default context size.

Sources: local `tmp/accepted-change-kazi-1792/FINDINGS.md` and
`tmp/accepted-change-go-1792/REPORT.md`. The facts above make this plan usable
without those ignored files. Commit only minimal synthetic fixtures, never raw
credential-bearing streams, provider identifiers, or private absolute paths.

## Discovery and use cases

Three scoped P0 use cases refine existing UC-033/UC-064/UC-065: receive the
complete declared change, receive relevant bounded context, and inspect truthful
run economics. Wiring exists but these boundary cases are broken or unverified.
Historical discovery (2026-09-06): the scratch manifest recorded this scoped
discovery without replacing the existing catalog. `docs/concept.md` is
architecture; `docs/design.md` does not exist.

Reuse ADR-0009 (predicate intent), ADR-0010 (bounded map context), ADR-0046
(honest unknown), ADR-0069 (measurement before default flips), and ADR-0086
(read versus write scope). E19/E36 and archived E48 already implemented tiers,
tool restriction, and economics: extend those seams, do not rebuild them.

## Scope and delivery

Historical proposed horizons (engineering estimates, not promises):

- Original plan: preserve the already-reviewed Go prototype/patch as a research artifact;
  implement and review the narrowly reproduced brief and usage-source fixes
  T74.1/T76.1. They are not yet implemented or production-certified. Ship only
  after their boundary and normal release gates, even if that extends past today.
- Original target week: complete E74-E76 and expand E77 into a bounded matched trial on
  unfamiliar changes. Prioritize acceptance quality, full attempt/review/repair
  accounting, and elapsed time; tune optional context only from those results.
- This quarter: only after repeatable quality-preserving gains, generalize the
  small task packet and verification interface; test task routing, retrieval, or
  reuse where attribution identifies a remaining bottleneck. Replan at that gate.
  No speculative graph platform or automatic model ladder is committed here.

E74 fixes intent delivery. E75 bounds optional orientation. E76 repairs accounting
and exposes honest provenance. E77 plans receipt ingestion and matched evaluation after these gates.
Keep Kazi a controller; no Go/Rust rewrite, new graph platform, harness replacement,
automatic model selection, or unrelated live-development cleanup.

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

## Parallel work, risks, and operating procedure

T76.1 may run alongside T74.1 (separate profile files); E75 follows T74.3.
Serialize all `loop.ex` work: T74.1, T75.1, T75.2, then T76.2. Each wave above
uses one implementer. Estimates are effort, not calendar deadlines. Claims and
fresh file ownership checks occur at execution, never inferred from this plan.
Use task worktrees. Tests must not touch host launchd, live daemon, subscription
configuration, or real credentials; run broad daemon suites only in disposable CI.
The risky implementation seams have task contracts at `docs/tasks/T74.1.md`,
`docs/tasks/T75.1.md`, and `docs/tasks/T76.1.md`. Other rows are interactive L2
work; expand their contracts before unattended container dispatch. No contract is
certified, and this repository has no `scripts/check-task-contract.sh` to run.
An oversized mandatory contract must remain complete or produce an explicit
pre-dispatch size error, never silently become a partial task.

No new ADR is needed for restoring declared intent. If implementation proposes
a new public budget/cost semantic, amend ADR-0046 before shipping that semantic.

## Progress Log

2026 09 06: Planned E74-E77 from the one-issue pilot; implementation and certification pending.

2026 09 07: Audited after rebasing the implementation branch onto 9daf6804. Reused #1839; 34 existing task-brief/process-contract/orientation/prompt cases pass. The planned public dispatch_contract_test.exs fixture is absent, so broader public/installed row criteria remain unverified. No row is closed solely from the prior merge.

### Verified delivery — 2026-09-07

PR #1844 merged as `3b3eec5e2469a8f6b50224e9a1daebd73222b13b`; independent review clear, CI executed 5,047 cases (234 doctests and 4,813 tests), with 124 excluded. Eight public-boundary contract cases cover file/proposal, tier 0/1, and long/absent brief. Four proposal cases failed before the scope/description preservation fix. The freshly downloaded v1.296.1 macOS arm64 artifact passed all 12 offline release scenarios, including four two-launch dispatch-contract cases; schema version 2. SHA-256: `bebf9516685bbb551e49d47b84c5c714f0f8ef2ecb6d10159c3b46ee5bfd9df9`. No active installation changed.

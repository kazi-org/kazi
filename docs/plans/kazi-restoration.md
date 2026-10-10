# Kazi restoration delivery plan

Status: executable-fidelity planning artifact; implementation and runtime admission remain gated.
Authority: this single Markdown file owns this bounded restoration plan. It does not replace Kazi's existing backlog, Foundry E33, APRL canonical tasks or fleetd records.
Plan identity: kazi:restoration-20261010. Source authority: kazi:repository.
Decision: [ADR 0090](../adr/0090-coordinated-kazi-restoration.md).
Basis: KAZI-RESTORATION-20261009, acknowledged by Kazi, Foundry and skills peers.

## Outcome and limits

Restore Kazi as the retained-context coding workhorse behind plan/apply/ship, then prove progress without an attached chat. Keep three separate receipts: bounded execution, attended independently reviewed and landed delivery, and unattended whole-plan operation. Only the third closes the need for repeated human refill.

All workers and independent reviewers inherit the selected session harness, model, reasoning and authentication route. No named-model defaults, implicit escalation, paid fallback or budget reset. Batch-size5 with15 compatible tasks targets3 concurrent workers when qualified capacity permits; the ceiling is not a quota and gates are not implementation members.

This artifact authorizes no application implementation, service activation, cloud spending, release or production deployment. Qualification tasks require their actual admission and finite resource envelope. Existing permissions persist; ask only for a genuinely missing decision. A separately selected economical-profile experiment is optional, never a switch of active workers.

## Architecture and source contract

Wazi owns pinned contract0.0.1 and semantic validation. Ordinary Markdown and native sources retain their authored authority; derived JSON/goals/views preserve task/plan IDs, revision, digest and acceptance. Source normalization is not admission. The ordinary adapter currently emits execution-complete edges without typed requirements or observations; it cannot manufacture review or landing proof.

Foundry E33 is the single durable whole-plan owner: supervised service, single-writer store/event journal, fenced leases and periodic reconciliation. APRL alone owns canonical enrolled lifecycle admission and author/review/fix/re-review/merge/landing successors. fleetd owns physical sessions. Kazi owns one admitted bounded author/fix/check batch and attempt recovery. plan/apply/ship are clients. No second whole-plan Kazi supervisor is proposed.

The source/owner-policy, admission, executor and result interface names, versions and custody rules must be frozen in T1.1 before implementation. Stable logical IDs, exact source and policy digest, claim and dispatch generations, role and contributor independence, candidate base/head and artifact/check binding, per-member outcomes and unknown-result semantics, idempotency key and remaining attempt/deadline/cost budget must cross these seams. A model's done statement, checkbox, raw process exit or projection cannot authenticate success. Unsupported, stale, ambiguous or unavailable inputs fail closed with explicit reasons.

## Dependencies on existing owners

Foundry [ADR0009](https://github.com/sirerun/foundry/blob/453076eed2057edc3335304c4488b7a2db8dbe81/docs/adr/0009-persistent-plan-maintenance-and-dispatch.md) and [E33](https://github.com/sirerun/foundry/blob/453076eed2057edc3335304c4488b7a2db8dbe81/docs/plans/E33-persistent-coordination.md) are the source baseline, not current runtime evidence. Reconcile their latest revisions and claims before scheduling.

- T33.0/T33.1 own native interface freeze and prerequisites; T33.2-T33.6 own persistence, maintenance/refill and execution adapters.
- T33.7-T33.9 own integrated verification, review and immutable local artifact.
- T33.10/T33.11 own authorized bounded local activation; T33.12 owns disconnected full-cycle acceptance; T33.13 owns12hour recovery/continuity; T33.14 owns operations handoff.
- T33.15 and AWS/production are outside this restoration's local acceptance. Their absence cannot block unrelated local interface/source work.
- APRL and fleetd retain their actual task IDs/admission; T1.1 records exact qualified versions and canonical task references. Missing mappings remain blocked, never guessed.
- Foundry E33 remains open. Its legacy split plan has earlier parser/checkpoint evidence only; evidence-preserving repair and the T33.0 freeze are required before affected dispatch under current policy. Preserve canonical IDs and history rather than copying or relabeling its authority. Current session inheritance supersedes historical model-specific owner labels. T31.33 is the local operations acceptance; T31.34 remains separate AWS acceptance.

These external references are evidence obligations, not locally dispatchable replicas. Local dependency lists contain only this document's IDs. T6.1 explicitly checks owner-qualified external receipts before unattended cutover. Typed external semantics remain in the owning service and explicit acceptance; do not weaken them into local checkbox completion.

## Verification, checkpoints and stop conditions

Reuse qualified project verification recipes and source-pinned fixtures. First prove deterministic15/5/3 scheduling; label it fixture-only. Then run one finite real batch and separately qualify real concurrency. Capture candidate custody and remote refs/PR state on success, failure and cancellation before trusting any no-integration flag. Independent review is a separate session bound to exact source and complete contributors.

False completion, missing/stale/duplicate receipts, unknown launch, cancellation, missed events and controller restart are required negatives. Preserve logical budgets/cooldown across restart. Every authoritative eligible item is owned or durably queued with reason, owner, since, prerequisite and next event/time trigger. Under qualified healthy services, observe a dispatch/queue decision within60s; a reconciliation sweep is at most60s. More than5minutes of unexplained eligible idle fails acceptance. Capacity waits are reported, not counted as launches. Empty queues with unfinished work park with durable triggers and no inference spending; they are not terminal success.

The unattended canary must disconnect all submitting clients, drain all original workers, then make a successor eligible and observe automatic dispatch. It includes independent negative review, bounded correction, re-review and verified landing, plus E33's12hour local observation. A paused/resumed job is not proof of crash recovery.

Milestone checkpoints: after attended delivery and after unattended qualification, the Foundry owner proposes a meaningful preview/staging demonstration under its qualified deployment authority. Preserve engineering review and landing. Record exact artifact/environment, owned checkpoint/target claim, readiness and a real user walkthrough plus edge case. Prefer immutable preview links; mutable staging supersedes the old packet and requires exact-build-confirmed feedback. Owner visual review stays pending while eligible work continues; only explicitly decision-gated dependents wait. No production permission or successful visual acceptance is inferred. Missing destination/authority/route blocks the checkpoint rather than inventing an executable deployment stage here. These external deployment obligations stay with Foundry; T6.1 verifies their receipts.

On failed checks or accepted review findings, the owning service creates stable bounded fix, affected verification and re-review successors; no source merge until current gates pass. Ordinary unenrolled repairs retain IDs and record new obligations in the ledger. Stop dependent work on exhausted budgets, unavailable authority or unresolved material scope; keep unrelated qualified work moving.

## Parallel Work

| Batch | Outcome / members | Owner | Prerequisites | Verification and delivery | Split conditions |
|---|---|---|---|---|---|
| KR1 | Freeze interfaces T1.1 | kazi-coordinator with skills/Foundry input | source and claim reconciliation | T1.2-T1.5 | unresolved authority or schema representation |
| KR2 | Qualify bounded executor T2.1 | kazi-implementation | T1.5 | T2.2-T2.5 | harness/context/custody incompatibility |
| KR3 | Route skills T3.1 | skills | T1.5; development may overlap KR2 on frozen interfaces, live enablement waits T2.5 | T3.2-T3.5 | missing capability or adapter version |
| KR4 | Prove attended delivery T4.1 | kazi-coordinator and independent reviewer | T2.5,T3.5 | T4.2-T4.5 | finite live capacity unavailable |
| KR5 | Release labeled bounded route T5.1 | skills | T4.5 | T5.2-T5.5 | active installation differs or unattended claims leak |
| KR6 | Qualify external path T6.1 and activate default T6.3,T6.8 | foundry-integration; skills owns route cutover | T1.5,T4.5 plus canonical E33/APRL/fleetd gates | T6.2 receipt review; T6.4-T6.7 source gates; T6.9 installed-route acceptance | source-only or fixture evidence cannot replace live gates |

KR6 interface qualification is critical-path work in parallel with KR1-KR3 where safe, not postponed behind unrelated cloud/product work. Its final joined acceptance waits on actual receipts. Requested/actual batch size, inherited launch selection, task coverage, tokens/cost when exposed, stage timing and correction effort are recorded per run. Unknown telemetry stays unavailable; no speedup is claimed from fewer rows.

## Work breakdown

### E1 -- Coordinated restoration
Acceptance: bounded execution and attended delivery are separately evidenced; unattended acceptance passes through the single qualified Foundry/APRL/fleetd/Kazi path with preserved authored authority.
fidelity: executable


#### KR1

- [ ] T1.1 Freeze source policy admission executor and result interfaces  Owner: kazi-coordinator  Est: dispatch-estimate  kind: agent  stage: preflight  deps: []  acc: [Current source and claims reconciled; Kazi Foundry and skills approve versioned source owner-policy admission executor and result contracts; ordinary Markdown and native identity plus exact revision digest acceptance and typed evidence mapping preserved; unsupported stale ambiguous inputs refuse execution; concrete gaps go to Wazi without speculative schema fork; E33 APRL fleetd canonical dependencies and finite resource policy recorded]
- [ ] T1.2 Verify KR1 candidate and evidence  Owner: verifier  Est: dispatch-estimate  kind: agent  stage: verify  deps: [T1.1]  acc: [Relevant behavioral fixtures and negative cases plus required formatting lint and conformance checks pass at exact source; record commands results and gaps; KR3 live tests wait for T2.5; no hosted CI live-provider or unattended claim from local fixtures]
- [ ] T1.3 Independently review KR1 candidate  Owner: independent-reviewer  Est: dispatch-estimate  kind: agent  stage: review  deps: [T1.2]  acc: [Separate session reviews full KR1 candidate including plan and evidence at exact base and head with contributor independence; concrete accepted findings resolved through fixes affected checks and re-review; approval bound to current subject]
- [ ] T1.4 Guarded rebase merge KR1 artifact  Owner: coordinator  Est: dispatch-estimate  kind: agent  stage: merge  deps: [T1.3]  acc: [Current checks and independent exact-head approval satisfy repository policy; guarded GitHub rebase merge preserves protections and records source receipt without fabricated statuses]
- [ ] T1.5 Verify landed KR1 artifact and qualified behavior  Owner: independent-verifier  Est: dispatch-estimate  kind: agent  stage: verify-landed  deps: [T1.4]  acc: [Target reachability source equivalence and relevant landed checks recorded; evidence releases only qualified descendants and never upgrades attended or fixture results to unattended acceptance]

#### KR2

- [ ] T2.1 Qualify retained bounded Kazi execution and candidate custody  Owner: kazi-implementation  Est: dispatch-estimate  kind: agent  stage: implement  deps: [T1.5]  acc: [Actual launch preserves inherited harness model reasoning and authentication route; retained multi-member context and per-member subject-bound evidence demonstrated; success failure cancellation and unknown launch cannot publish or merge ahead of outer authority; attempt recovery preserves candidate artifacts ownership budget and cooldown]
- [ ] T2.2 Verify KR2 candidate and evidence  Owner: verifier  Est: dispatch-estimate  kind: agent  stage: verify  deps: [T2.1]  acc: [Relevant behavioral fixtures and negative cases plus required formatting lint and conformance checks pass at exact source; record commands results and gaps; KR3 live tests wait for T2.5; no hosted CI live-provider or unattended claim from local fixtures]
- [ ] T2.3 Independently review KR2 candidate  Owner: independent-reviewer  Est: dispatch-estimate  kind: agent  stage: review  deps: [T2.2]  acc: [Separate session reviews full KR2 candidate including plan and evidence at exact base and head with contributor independence; concrete accepted findings resolved through fixes affected checks and re-review; approval bound to current subject]
- [ ] T2.4 Guarded rebase merge KR2 artifact  Owner: coordinator  Est: dispatch-estimate  kind: agent  stage: merge  deps: [T2.3]  acc: [Current checks and independent exact-head approval satisfy repository policy; guarded GitHub rebase merge preserves protections and records source receipt without fabricated statuses]
- [ ] T2.5 Verify landed KR2 artifact and qualified behavior  Owner: independent-verifier  Est: dispatch-estimate  kind: agent  stage: verify-landed  deps: [T2.4]  acc: [Target reachability source equivalence and relevant landed checks recorded; evidence releases only qualified descendants and never upgrades attended or fixture results to unattended acceptance]

#### KR3

- [ ] T3.1 Integrate plan apply ship with the qualified execution adapter  Owner: skills  Est: dispatch-estimate  kind: agent  stage: implement  deps: [T1.5]  acc: [One versioned route preserves conformance IDs source ownership batch semantics and independent review; unavailable Kazi selection or admission produces explicit capability refusal without direct-worker or shell-loop fallback; old contradictory execution guidance is marked unqualified; fixture development may precede T2.5 but no live enablement before its verified receipt]
- [ ] T3.2 Verify KR3 candidate and evidence  Owner: verifier  Est: dispatch-estimate  kind: agent  stage: verify  deps: [T3.1, T2.5]  acc: [Relevant behavioral fixtures and negative cases plus required formatting lint and conformance checks pass at exact source; record commands results and gaps; KR3 live tests wait for T2.5; no hosted CI live-provider or unattended claim from local fixtures]
- [ ] T3.3 Independently review KR3 candidate  Owner: independent-reviewer  Est: dispatch-estimate  kind: agent  stage: review  deps: [T3.2]  acc: [Separate session reviews full KR3 candidate including plan and evidence at exact base and head with contributor independence; concrete accepted findings resolved through fixes affected checks and re-review; approval bound to current subject]
- [ ] T3.4 Guarded rebase merge KR3 artifact  Owner: coordinator  Est: dispatch-estimate  kind: agent  stage: merge  deps: [T3.3]  acc: [Current checks and independent exact-head approval satisfy repository policy; guarded GitHub rebase merge preserves protections and records source receipt without fabricated statuses]
- [ ] T3.5 Verify landed KR3 artifact and qualified behavior  Owner: independent-verifier  Est: dispatch-estimate  kind: agent  stage: verify-landed  deps: [T3.4]  acc: [Target reachability source equivalence and relevant landed checks recorded; evidence releases only qualified descendants and never upgrades attended or fixture results to unattended acceptance]

#### KR4

- [ ] T4.1 Prove bounded and attended independently landed delivery  Owner: kazi-coordinator  Est: dispatch-estimate  kind: agent  stage: verify  deps: [T2.5, T3.5]  acc: [Deterministic15tasks5perbatch3workers fixture and one finite real inherited-selection batch produce separate evidence; failed check repair and independent negative review fix re-review guarded rebase and verified landing complete; actual concurrent canary uses qualified finite capacity; stale duplicate premature-done cancellation reconnect and restart negatives recorded without claiming unattended whole-plan operation]
- [ ] T4.2 Verify KR4 candidate and evidence  Owner: verifier  Est: dispatch-estimate  kind: agent  stage: verify  deps: [T4.1]  acc: [Relevant behavioral fixtures and negative cases plus required formatting lint and conformance checks pass at exact source; record commands results and gaps; KR3 live tests wait for T2.5; no hosted CI live-provider or unattended claim from local fixtures]
- [ ] T4.3 Independently review KR4 candidate  Owner: independent-reviewer  Est: dispatch-estimate  kind: agent  stage: review  deps: [T4.2]  acc: [Separate session reviews full KR4 candidate including plan and evidence at exact base and head with contributor independence; concrete accepted findings resolved through fixes affected checks and re-review; approval bound to current subject]
- [ ] T4.4 Guarded rebase merge KR4 artifact  Owner: coordinator  Est: dispatch-estimate  kind: agent  stage: merge  deps: [T4.3]  acc: [Current checks and independent exact-head approval satisfy repository policy; guarded GitHub rebase merge preserves protections and records source receipt without fabricated statuses]
- [ ] T4.5 Verify landed KR4 artifact and qualified behavior  Owner: independent-verifier  Est: dispatch-estimate  kind: agent  stage: verify-landed  deps: [T4.4]  acc: [Target reachability source equivalence and relevant landed checks recorded; evidence releases only qualified descendants and never upgrades attended or fixture results to unattended acceptance]

#### KR5

- [ ] T5.1 Release labeled bounded and attended skill routing  Owner: skills  Est: dispatch-estimate  kind: agent  stage: implement  deps: [T4.5]  acc: [Active supported harness aliases match independently reviewed landed skills and qualified canary bindings; contradictory legacy guidance retired; installed capability reports distinguish bounded attended and still-unqualified unattended behavior; unattended default remains blocked until T6.2 and its exact native receipts]
- [ ] T5.2 Verify KR5 candidate and evidence  Owner: verifier  Est: dispatch-estimate  kind: agent  stage: verify  deps: [T5.1]  acc: [Relevant behavioral fixtures and negative cases plus required formatting lint and conformance checks pass at exact source; record commands results and gaps; KR3 live tests wait for T2.5; no hosted CI live-provider or unattended claim from local fixtures]
- [ ] T5.3 Independently review KR5 candidate  Owner: independent-reviewer  Est: dispatch-estimate  kind: agent  stage: review  deps: [T5.2]  acc: [Separate session reviews full KR5 candidate including plan and evidence at exact base and head with contributor independence; concrete accepted findings resolved through fixes affected checks and re-review; approval bound to current subject]
- [ ] T5.4 Guarded rebase merge KR5 artifact  Owner: coordinator  Est: dispatch-estimate  kind: agent  stage: merge  deps: [T5.3]  acc: [Current checks and independent exact-head approval satisfy repository policy; guarded GitHub rebase merge preserves protections and records source receipt without fabricated statuses]
- [ ] T5.5 Verify landed KR5 artifact and qualified behavior  Owner: independent-verifier  Est: dispatch-estimate  kind: agent  stage: verify-landed  deps: [T5.4]  acc: [Target reachability source equivalence and relevant landed checks recorded; evidence releases only qualified descendants and never upgrades attended or fixture results to unattended acceptance]

#### KR6

- [ ] T6.1 Qualify canonical unattended continuation and checkpoint receipts  Owner: foundry-integration  Est: dispatch-estimate  kind: agent  stage: verify  deps: [T1.5, T4.5]  acc: [Existing E33 T33.0 through T33.14 and actual APRL fleetd admission receipts are independently qualified at current source and policy; real client-disconnected review correction landing and successor dispatch after original workers exit pass with restart missed-event false-completion cancellation and stable budgets;12hour local observation and version-bound nonblocking preview checkpoint are evidenced; no duplicate implementation or operational dispatch is created by this observer task]
- [ ] T6.2 Independently accept unattended route and durable handoff  Owner: independent-acceptance  Est: dispatch-estimate  kind: agent  stage: review  deps: [T6.1, T5.5]  acc: [Independent consumer authenticates current native source artifact environment and complete-contributor receipts; no-silent-idle thresholds and operations ownership backup restore alert stop controls pass; owner visual feedback remains explicitly pending or artifact-bound accepted without blocking unrelated work; acceptance releases the explicit T6.3 through T6.9 cutover chain but is not evidence of enabled defaults]

- [ ] T6.3 Prepare qualified unattended default route candidate  Owner: skills  Est: dispatch-estimate  kind: agent  stage: implement  deps: [T6.2]  acc: [Source and configuration candidate makes plan apply ship resolve to the accepted Foundry APRL fleetd Kazi route with pinned versions capability negotiation explicit refusal and rollback to an accurately labeled bounded route only by authorized choice; no second scheduler or premature service admission]
- [ ] T6.4 Verify default-route candidate  Owner: verifier  Est: dispatch-estimate  kind: agent  stage: verify  deps: [T6.3]  acc: [Positive and unavailable stale wrong-source wrong-selection unknown-launch negatives pass at exact source; Wazi and required repository checks pass; source configuration and installer artifacts pinned]
- [ ] T6.5 Independently review default-route candidate  Owner: independent-reviewer  Est: dispatch-estimate  kind: agent  stage: review  deps: [T6.4]  acc: [Separate current-selection reviewer approves full cutover candidate at exact base and head with complete contributor independence and resolved concrete findings; native lifecycle authority remains unchanged]
- [ ] T6.6 Guarded rebase merge default-route candidate  Owner: coordinator  Est: dispatch-estimate  kind: agent  stage: merge  deps: [T6.5]  acc: [Current qualified checks and exact-head independent approval satisfy protection policy; guarded GitHub rebase merge records the accepted source and configuration without fabricated checks]
- [ ] T6.7 Verify landed default-route source  Owner: independent-verifier  Est: dispatch-estimate  kind: agent  stage: verify-landed  deps: [T6.6]  acc: [Target reachability tree equivalence and affected landed checks bind the exact artifact approved for skills installation; source landing is not evidence of active cutover]
- [ ] T6.8 Install approved unattended skill route  Owner: skills  Est: dispatch-estimate  kind: agent  stage: implement  deps: [T6.7]  acc: [Existing authorized skill installation mechanism activates exact approved artifact and route configuration for supported harness aliases under one recorded owner with recoverable previous state; verify current native service bindings before activation; no new service deployment admission spending or production permission inferred]
- [ ] T6.9 Independently verify active unattended route and close handoff  Owner: independent-acceptance  Est: dispatch-estimate  kind: agent  stage: verify  deps: [T6.8]  acc: [Actual installed aliases capability negotiation and default invocation resolve to the accepted persistent route; one finite owner-admitted post-install successor progresses without chat refill and retains refusal on unavailable authority; exact source artifact environment and runtime evidence plus rollout owner rollback and operations handoff recorded; only this receipt closes default restoration]

## Delivery and open gates

This is a planning artifact. All task checkboxes remain open until evidence is recorded by their actual owner. Planning-document review/merge does not complete the execution tasks above. This document's Wazi gate validates source reader compatibility, pinned schema and semantics; it does not authenticate runtime receipts or admit work.

Open gates: exact live source-policy/admission mapping; inherited executor selection and context; remote candidate custody; persistent E33 service; qualified APRL/fleetd and shared admission; actual bounded/attended/unattended receipts. Missing tools or source schema incompatibility leave a blocked draft. Current APIs, activation commands and machine acceptance are frozen through T1.1 rather than invented here.

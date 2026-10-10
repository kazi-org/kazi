# ADR 0090: Restore Kazi through one persistent delivery owner

## Status
Accepted coordination decision; implementation and runtime qualification pending.

## Context
The owner wants high-quality retained-context batch delivery without repeatedly restarting a chat. KAZI-RESTORATION-20261009 was closed with acknowledgements from the Kazi, Foundry and skills sessions. Existing global skills now support coherent batches, evidence-preserving plan rewrite, reusable verification and nonblocking preview/staging feedback.

A Markdown loop, current Kazi read-model daemon, successful process exit or pause/resume checkpoint is insufficient evidence for persistent whole-plan progression.

## Decision
Keep Wazi as schema/semantic steward, preserving each ordinary Markdown or native authored authority. Keep stable source/plan/task IDs, revision/digest and acceptance across derived execution contracts. Start with pinned contract0.0.1; change the steward contract only for a demonstrated representation gap. The ordinary adapter's execution-complete edges cannot become authenticated review/landing judgments.

Use Foundry's accepted ADR0009/E33 as the single durable whole-plan maintenance/refill owner. APRL owns canonical lifecycle admission and independent review/fix/re-review/merge/verified landing. fleetd owns physical sessions. Kazi owns bounded admitted retained-context author/fix/check convergence and attempt recovery. plan/apply/ship are clients. Do not add a standalone Kazi whole-plan supervisor.

This specializes the existing Sire-governed bounded-job direction, not a competing fleet/governance service. [ADR0087](0087-kazi-plans-sire-schedules-one-goal-per-container.md) remains proposed and does not supply admission. Exact interface/store/process bindings still require the KR1 freeze and qualification; planning does not claim they are implemented.

All child workers and independent reviewers inherit the current selected harness/model/reasoning/auth route, with no implicit fallback or budget reset. Deterministic code owns eligibility, claims, receipt checks, timers and recovery. Independent review remains separate even when using identical session settings.

Keep bounded execution, attended full delivery and unattended whole-plan operation as distinct receipts. A bounded opt-in may ship first; no unattended-default cutover before real Foundry/APRL/fleetd/Kazi qualification. E33 is on the critical path now, with safe interface work parallel to the skills/executor work.

Preview/staging checkpoints remain pending while eligible work continues unless explicitly decision-gated. Own checkpoint and target mutations; bind feedback to immutable artifacts or explicit staging supersession. Production and new spend remain separately authorized.

## Consequences and acceptance
Reuse existing native tasks rather than create a duplicate scheduler or writable plan. Require source/authority binding, actual candidate custody, finite live trials and owner-qualified receipts. Every eligible item has ownership or a durable reason/next trigger. Under healthy qualified services, dispatch/queue decision occurs within60s; periodic reconciliation is at most60s and unexplained eligible idle over5minutes fails. An empty worker pool does not complete unfinished work.

The full canary disconnects clients, observes independent repair/re-review and verified landing, drains original workers, admits newly ready successors, survives restart/missed events, rejects stale/duplicate/premature-done results and preserves budgets. Reuse E33's12hour local observation; AWS/production evidence stays separate.

See the single-file [restoration plan](../plans/kazi-restoration.md) for prospective ownership, gates and external canonical task references. This decision and plan create no runtime admission or implementation dispatch.

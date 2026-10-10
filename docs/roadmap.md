# Kazi roadmap

Current direction: 2026-10-01. This document states priorities, not authority
to dispatch jobs, change architecture, or spend on evaluations.

## Direction

Keep Kazi a bounded convergence controller for one declared goal inside a
Sire-governed coding job. Sire owns authorization, scheduling, global budgets,
credentials, job recovery and governed publication. Kazi validates the goal,
observes predicates, drives bounded repairs and returns the patch and evidence.
Existing standalone capabilities remain supported; expanding a second fleet
control plane is not the priority.

The next question is whether this integration reduces supervision per
independently accepted, landed change. Provider token prices alone cannot
answer that question. See the [fleet recommendation](kazi-in-a-sire-governed-fleet.md)
and [ADR-0087](adr/0087-kazi-plans-sire-schedules-one-goal-per-container.md).

## Delivered foundations

- E74 preserves the declared task contract at dispatch.
- E76 conserves usage and distinguishes estimates from provider-reported cost.
- E78 qualifies behavioral acceptance and distinguishes mutation detection
  from checker failure.
- E79 bounds repair attempts and preserves reproducible handoff evidence.
- E80 supplies Fanisi's accepted-change effort and landing ledger.

These engineering scopes are complete. Convergence remains the declared
predicate verdict; independent acceptance and verified landing remain separate
claims under [ADR-0089](adr/0089-accepted-change-economics.md).
See the [delivery record](plans/accepted-change-delivery.md) for release evidence.

## Remaining work

1. Verify the existing governed integration's uptake and sequencing gates
   before proposing further implementation. Local entrypoint work is not
   proof that the surrounding fleet has adopted it.
2. Define a bounded evaluation of supervision per accepted, landed change,
   charging coordinator, reviewer, failed-attempt and recovery effort.
3. Resolve missing cost evidence where possible and retain unknowns where
   receipts or prices cannot be recovered.

E77's completed cohorts did not establish an economics advantage and produced
no operational landings. Their authorization has expired; any new paid study
needs its own protocol and authorization. [Results](e77-evaluation-2026-09-08.md).

E75 orientation tuning is deferred, with no executable task queue. It is not a
prerequisite for the delivered foundations or the completed E77 study.
Generic external executors and optional UI tier hints are outside this milestone.

## Engineering backlog and maintenance

[The build plan](plan.md) retains the separate engineering backlog. October 1
triage source work completes T70.8 and adds CLI-help and stuck/budget regression
coverage; [PR #1859](https://github.com/kazi-org/kazi/pull/1859) records integration
and verification, without claiming a production upgrade.

Update this roadmap when an accepted decision, delivered milestone or evaluation
changes these priorities. Keep task mechanics in epic files and measurements in
reports. Earlier horizon proposals and release narratives are
[historical](https://github.com/kazi-org/kazi/blob/4549096bb9a15d2a3e03715ea80807215cbaa89d/docs/roadmap.md).

## Coordinated restoration

The bounded Kazi and unattended Foundry integration sequence is recorded in the
[restoration plan](plans/kazi-restoration.md) and
[ADR0090](adr/0090-coordinated-kazi-restoration.md). This is a gated planning artifact,
not runtime admission or evidence of unattended operation. Existing backlog and
canonical service tasks retain their authority.

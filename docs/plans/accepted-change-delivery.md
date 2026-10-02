# Accepted-change delivery: current state and next question

Status: 2026-10-01. Engineering delivery is complete; all-in economics and
operational landing outcomes remain incomplete.

## Delivered

| Scope | Result | Evidence |
| --- | --- | --- |
| E74: full dispatch contract | Complete | [Delivery record](E74-dispatch-contract.md) |
| E76: usage and cost provenance | Complete | [Delivery record](E76-truthful-accounting.md) |
| E78 / UC-073: acceptance integrity | Complete | [Delivery record](E78-acceptance-integrity.md) |
| E79 / UC-074: bounded repair | Complete | [Delivery record](E79-bounded-repair.md) |
| E80 / UC-075: accounting machinery | Complete; measured outcome partial | [Delivery record](E80-accepted-change-ledger.md) |
| E77: matched candidate evaluation | Completed; no demonstrated advantage | [Report](../e77-evaluation-2026-09-08.md) |

Kazi source and downloaded-release verification reached v1.297.0; Fanisi's
ledger release reached v0.1.0. These are recorded delivery milestones, not a
claim about the currently installed binary or paid-model certification.

The original E77 cohort accepted 2/3 candidates in each arm, with about 20% more
known provider dollars and 52% more attempt wall time for Kazi. The resumed
raised-allowance cohort accepted 2/3 direct candidates and 1/3 Kazi candidates.
No experimental candidate was operationally landed. Missing receipts,
coordinator prices and other uncovered effort prevent an all-in cost verdict.
The report preserves exact spend, reserves and coverage; do not treat reserves
as settled spend or missing cost as zero.

## Current direction

Kazi remains a bounded convergence runtime inside Sire-governed jobs. Sire owns
fleet governance and publication; Fanisi owns independent acceptance and
cross-harness accounting. Follow [ADR-0089](../adr/0089-accepted-change-economics.md)
and the [dated fleet recommendation](../kazi-in-a-sire-governed-fleet.md).

The next evaluation question is supervision per independently accepted, landed
change in that integration. Verify uptake and sequencing gates first, then
specify the cohort, independent review, landing evidence, recovery effort and
complete cost coverage. This document authorizes neither implementation nor
paid execution. Completed-study approval does not carry forward.

## Deferred

[E75](E75-bounded-orientation.md) is an optional orientation idea, not an active
implementation queue or a dependency of the completed delivery. Broader
retrieval tuning, generic external executors and changes to model defaults
remain outside this milestone.

Earlier wave schedules, pilot proposals and superseded execution dependencies
are retained in [Git history](https://github.com/kazi-org/kazi/blob/4549096bb9a15d2a3e03715ea80807215cbaa89d/docs/plans/accepted-change-delivery.md),
not presented as current instructions.

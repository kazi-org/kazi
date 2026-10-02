# Kazi in a Sire-governed coding fleet

Status: recommendation, 2026-09-08. Written after the E77 evaluation and a
limited private integration review. This is not a new architecture ruling, an
approved implementation plan, or authorization for more paid experiments.
Existing ADRs and the integration's sequencing gates remain in force.

## Recommendation

Retain Kazi as a small, bounded convergence runtime inside Sire-governed coding
jobs. Prioritize completing and measuring that integration over expanding
Kazi's independent fleet-orchestration features.

The product question is: **does Kazi reduce the supervision required per accepted,
landed change when Sire already supplies the surrounding infrastructure?**
Cheaper model tokens alone are insufficient justification for continued work.

## Ownership boundary

| Component | Owns |
| --- | --- |
| Sire | Work authorization, fleet scheduling, global budgets, credential grants, machine/job leases, lifecycle recovery, approvals and governed publication. |
| Container or node runtime | Isolated workspace, pinned tools, resource limits, process execution and transport of checkpoints/artifacts. |
| Kazi | One assigned goal: validate its input contract, observe acceptance predicates, drive bounded local repairs, detect lack of progress, and return the patch plus evidence. |
| Coding harness | Reasoning, repository inspection, edits and tool use within the assigned job. |

Cloud-specific placement belongs to Sire and its execution infrastructure.
Kazi's convergence logic should not need separate AWS, Azure, GCP and on-premises
implementations. Platform-specific build tools can differ without changing who
owns the job or its acceptance contract.

Sire owns infrastructure retries and reassignment; Kazi owns bounded repair
iterations within an attempt. Restarting a container must not silently replenish
the logical job's budget or erase failed attempts. Sire cancellation and grant
revocation must remain effective across the entire child-process tree.

Kazi should not acquire fleet-scheduling authority, create replacement machines,
carry a second coordination bus, or obtain broader credentials to finish a job.
In the governed lane described by HQ, publication is outside the container and
Kazi holds no GitHub credential. Predicate success is evidence for the governed
review/publication path, not permission to bypass it.

## What already exists, and what remains to prove

This recommendation follows the existing boundary in
[ADR-0087: Kazi plans, Sire schedules, one goal per container](adr/0087-kazi-plans-sire-schedules-one-goal-per-container.md)
and [ADR-0086: write paths and the agent-instruction projection](adr/0086-write-paths-and-the-agents-md-projection.md).
The [local entrypoint proposal](plans/E-KAZI-ENTRYPOINT.md) supplies historical
integration context. Neither its local task state nor this recommendation
establishes fleet uptake; verify the surrounding integration's current gates
before authoring work.

The ownership recommendation also reflects a limited private integration
review summarized below: the reviewed design keeps Kazi as a convergence
workload, places governed container entrypoint work behind sequencing gates,
and assigns job lifecycle and lease reconciliation to the surrounding control
plane. The public Kazi ADRs linked above remain the source references for Kazi's
own boundary.

At inspection on 2026-09-08, governed-entrypoint uptake rows in the reviewed
private material were still unchecked, and the reviewed container entrypoint
still ran the harness before a post-hoc Kazi check. Kazi's local CLI already
exposed single-node, lane-contract and integration-command controls. This is a
dated, limited private integration observation, not proof of deployment status.
Recheck current integration artifacts and required uptake, QA and
architecture-review gates before implementation.

## What E77 establishes

The [evaluation report](e77-evaluation-2026-09-08.md) and
[structured results](e77-evaluation-2026-09-08.json) preserve the measurements:

- Original three-task comparison: both arms accepted 2/3 candidates; Kazi used
  about 20% more provider dollars and 52% more attempt wall time.
- Raised-allowance follow-up: direct accepted 2/3 candidates and Kazi 1/3.
- A Kazi mailbox patch passed the frozen grader and reached convergence but
  violated malformed-header handling. Independent, unblinded review rejected it.
- No experimental candidate was operationally landed. Some provider costs and
  coordinator billing remain unknown.

These results do not establish a coding-economics advantage for Kazi. They also
do not measure its contribution to fleet recovery or reduced human supervision.
That distinction warrants a focused fleet evaluation, not an assumption that the
integration will pay off. Containers protect execution boundaries; they do not
make incomplete predicates a complete correctness specification.

## Next engineering and evaluation step

1. Complete one existing Sire-to-container-to-Kazi governed lane, respecting the
   current sequencing gates. Reuse the existing job/prompt and lane-contract
   surfaces; do not introduce another scheduler or job type.
2. Exercise cancellation, container death, reassignment, stale input rejection,
   budget exhaustion and artifact recovery. Preserve logical job identity,
   attempt history and unresolved outcomes; verify that recovery does not
   duplicate publication or reset the spending allowance.
3. Preregister a comparison on new tasks: Sire plus a direct harness versus
   Sire plus Kazi plus the same harness. Both arms receive identical isolation,
   governance, acceptance checks, review standards and accounting.
4. Measure human interventions and active supervision minutes per accepted,
   landed change; acceptance and false-success rates; recovery after interruption;
   total model/compute/review cost; elapsed time; and duplicated or lost work.
   Include failures and unknown costs in the results.

Set numeric success thresholds, sample size, spending limits and stop rules
before dispatch. The prior experiment's budget and autonomy window are not
standing authorization for this new trial.

Continue investment if the comparison demonstrates materially less supervision
or better accepted, landed outcomes at an explicitly acceptable total cost.
If Sire plus direct execution achieves equivalent outcomes and recovery with
less complexity, retain only Kazi's useful verification components and stop
expanding the separate convergence runtime. Do not make either decision solely
from token prices or convergence counts.

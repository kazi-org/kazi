# E77 accepted-change feasibility — 2026-09-08

The completed original comparison found no acceptance advantage for Kazi: both arms accepted two of three candidates. Kazi used about 20% more provider dollars and 52% more attempt wall time. The raised-allowance follow-up accepted 2/3 direct candidates and 1/3 Kazi candidates; its direct-arm cost remains a lower bound because some earlier requests lack receipts.

This study compares direct Claude Code with Kazi-driven Claude Code on three private frozen tasks, using OpenRouter `z-ai/glm-5.3-flash` and Z.AI in both arms. The follow-up repeats those tasks; it is not a new unfamiliar-task sample. [Structured results](e77-evaluation-2026-09-08.json) accompany this report.

## Candidate outcomes

### Original allowance (A3): 0.70 CLI estimated dollars

| Arm | Accepted | Known provider cost | Attempt wall time | Provider cost per acceptance |
| --- | ---: | ---: | ---: | ---: |
| Direct | 2/3 | $0.02437561 | 12.96 min | $0.01218780 |
| Kazi | 2/3 | $0.02931124 | 19.68 min | $0.01465562 |

| Task | Arm | Review | Frozen grading | Forwarded requests |
| --- | --- | --- | --- | ---: |
| Usage window | Kazi | accept | 466 outcomes; 10 exclusions | 9 |
| Usage window | Direct | accept | 466 outcomes; 10 exclusions | 11 |
| Mailbox identity | Kazi | accept | 167 outcomes; 5 exclusions | 13 |
| Mailbox identity | Direct | accept | 167 outcomes; 5 exclusions | 12 |
| Ratchet target | Direct | reject | 4 outcomes; 0 exclusions; 3 feature failures, regression not run | 16 |
| Ratchet target | Kazi | reject | 4 outcomes; 0 exclusions; 3 feature failures, regression not run | 22 |

### Raised allowance (A4 usage pair + A5 remaining pairs): 3.874 CLI estimated dollars

| Arm | Accepted | Known provider cost | Attempt wall time | Provider cost per acceptance |
| --- | ---: | ---: | ---: | ---: |
| Direct | 2/3 | $0.03444276 lower bound | 18.49 min | undefined |
| Kazi | 1/3 | $0.03687785 | 19.01 min | $0.03687785 |

| Task | Arm | Review | Frozen grading | Forwarded requests |
| --- | --- | --- | --- | ---: |
| Usage window | Kazi | accept | 466 outcomes; 10 exclusions | 12 |
| Usage window | Direct | accept | 466 outcomes; 10 exclusions | 24 |
| Mailbox identity | Direct | accept | 167 outcomes; 5 exclusions | 10 |
| Mailbox identity | Kazi | reject | 167 outcomes; 5 exclusions | 12 |
| Ratchet target | Direct | reject | 4 outcomes; 0 exclusions; 3 feature failures, regression not run | 24 |
| Ratchet target | Kazi | reject | 4 outcomes; 0 exclusions; 3 feature failures, regression not run | 24 |

All attempts, including failed and rejected candidates, contribute to arm totals. Attempt wall time includes baseline, execution and final grading; it excludes uninstrumented review duration and time waiting for the shared build lease. Acceptance is a reviewed candidate, not a production landing. The original and raised-allowance comparisons are not pooled across their differing limits.

## Why grading and acceptance differ

The follow-up Kazi mailbox patch passed all 167 frozen feature/regression outcomes (five exclusions) and the controller reported convergence. Review rejected it: its custom fallback accepts a malformed nonempty header after the standard parser rejects it, instead of returning the required error. A separate one-case audit copied the submitted helpers unchanged and demonstrated the defect. The same counterexample passed against the direct patch. This is post-dispatch review evidence under the original contract, not a retroactive change to the frozen grader. Neither worker received the finding or a repair pass.

## Protocol, amendments and interruptions

Both arms had 24 total CLI turns, 24 forwarded provider requests, 900 execution seconds and 8,192 output tokens per response. Direct had one session; Kazi could use two sessions with 12-turn/request reservations each. The follow-up raised only the CLI estimated-dollar allowance from 0.70 to 3.874 (1.937 per Kazi session); actual request/time/output/provider limits and the grader stayed fixed. CLI estimates are not provider receipts.

The original authorization began at 08:12:28 UTC on September 8 with a $10 spending limit. The later ten-hour autonomy grant extended the work window through approximately 20:44 UTC without adding funds. Paid runs retained the stricter original 20:12:28 UTC deadline. No model escalation occurred. The coordinator worked in Codex; all experimental coding workers used the requested GLM model.

- Two original setup failures occurred before provider dispatch: credential delivery through a scrubbed environment and a retained branch collision. They remain recorded.
- A paid preparation attempt produced an accepted usage-window candidate but incomplete receipt coverage. Its known cost is $0.006474695; its full $3.874 reserve remains held.
- A synthetic 16-output-token request cost $0.0000052 and exposed a live stream-accounting defect. [Fanisi PR #11](https://github.com/kazi-org/fanisi/pull/11) fixes the completed-stream `data: [DONE]` trailer and permits error-terminal accounting only with complete admission evidence. Historical ledgers were not rewritten.
- A3 retained the original CLI ceiling. Direct ratchet stopped at a reported $0.728305 while actual receipted cost was $0.014032575. Kazi Gmail reported `over_budget`, but its final candidate passed independent grading and review.
- A4 initially stopped after the usage pair: direct used 24 request slots, with 13 complete HTTP 200 streams and 11 HTTP 429 responses lacking generation receipts. An additional CLI-generated identifier is unresolved.
- On resume, a recorded accounting amendment retained $1.937 for all 11 unreceipted requests plus one extra full-request allowance, while counting the 13 receipted requests separately. Missing receipts were not marked complete and HTTP 429 costs were not assumed to be zero. The earlier preparation hold was unchanged.
- After a machine reboot, temporary protected binaries were missing. Both were restored to their exact original hashes. A third pre-provider setup failure stopped during protected-input hashing before any worktree or inference request; its record remains. A5 runs the four remaining Gmail/ratchet rows in fresh output directories with identical task configurations apart from paths.

## Accounting and validation

Known provider spend across all coding attempts and the diagnostic is **$0.13148736**. Conservative unresolved reserves total **$5.811**, and **$4.06398734** remains unallocated. These reserves are not observed charges. The full preparation reserve includes its known cost; that cost is not counted twice. The A4 request-level reserve covers only unknown calls, so its known receipts are counted separately.

Coordinator/reviewer dollars and original preparation effort are unknown. The provider ledger therefore cannot certify compliance with an all-in $10 invoice or establish end-to-end savings. Reviews were performed separately from the coding workers with arm identity visible; active review duration was not instrumented.

The pinned runner fix passed 151 named race-enabled test outcomes, with five explicit opt-in skips; installed admission/lifecycle coverage passed seven scenarios (nine named outcomes including parents), plus 18 offline ledger checks. macOS/Linux CI passed before merge. Six task/arm reference controls passed using the unchanged grader, and two additional controls checked the raised CLI allowance. The resumed reserve checker passed 15 tests covering missing/duplicate evidence, mismatched identities, changed limits and contradictory totals. The mailbox review audit executed one case per arm: direct passed and Kazi failed.

No experimental candidate was operationally landed. Cost per accepted landed change is undefined, and the seven-day landing follow-up has not begun. Keep the existing default policy: these small, repeated-task comparisons do not establish general capability or savings.

## Evidence identities

- Original frozen manifest: `6f064aca2fc07c0782366d62efc47dcc80696e04d9f58433acdf83ed6fd6bdb1`.
- amendment-A3.json: `aefdbfe0d43de492810f1edcfc577821e5c6ca1652c8c055a2e403ef180e8f3e`.
- amendment-A4.json: `fdf92d50135271589867e86d4add0d973728639c285b8c24f38324aaf1e78fb4`.
- amendment-A4-resume.json: `ebe2c8a71587fcd1cf3d65d2c1a2a7f99cad8c1a3e5cb5c2702916f1ae426409`.
- amendment-A5.json: `35f063c68181b3a73bf416b21860f9b72822984432f2f37f71a6f6cd9bbbdcc4`.
- Runner binary: `81f811bf13375faf5a6354cbd69d2433a43f79e8263a1dc3523cc35c5fed0c91`.
- Merged Fanisi source: `88100a077f9893b1ca2daffc82e88fbd72b2ef28`.

Private fixtures, candidate source, receipts, reviews and full manifests remain in the ignored evaluation bundle. The structured public results contain hashes and measurements, not private payloads.

## Coordinator observation

The cumulative Codex export observed 24,717,036 input tokens (including 24,323,328 cached) and 101,080 output tokens through 2026-09-08T09:49:00.951Z. This partial observation can overlap the requested window at its boundaries. Dollars remain unknown and are excluded from provider cost-per-acceptance. A later export failed because counters reset inconsistently after resume; the earlier partial snapshot is retained rather than presented as a full-session total.

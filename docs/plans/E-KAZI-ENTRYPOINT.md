# E-KAZI-ENTRYPOINT -- kazi as the governed lane entrypoint (single_node --in-place)

Back-link: not wired into [docs/plan.md](../plan.md)'s master index. This is a
planning artifact only (dispatched to the kazi session as a scoping task,
2026-09-05); it stays untracked in this worktree until chief-architect or a
human decides to mint it. Task ids below (`TKE.N`) are placeholders -- when
this lands in the master index it gets a real epic number and its tasks are
renumbered to match.

fidelity: planning

## 0. What this changes, and why

hq ruled (relayed as dec-0849, founder-direct, 2026-09-05) that a governed
lane container stops running `claude -p <assembled prompt>` directly and
instead runs `kazi apply <goal> --single-node --in-place` at a pinned task
sha: kazi renders its own per-directory node (ADR-0086), runs its own
grind/observe loop, and its predicates decide the Job's outcome, rather than
an LLM harness self-reporting a status an outer script trusts.

This document plans three things, scoped exactly as dispatched:

1. The kazi-side build: `--single-node --in-place` as a first-class lane
   entrypoint mode, the `[integration]`/resumable-apply work so kazi can open
   and continue a PR itself, and a stable Job-outcome shape.
2. The hq-side (and one sire-side) dependencies this needs, named for
   sire-planner to mint as real rows -- not specified in task-shape detail,
   since they are not this plan's to author.
3. Ordering across both sides and one concrete integration test.

### Correction: ADR 0136 is a sire ADR, not an hq ADR

The dispatch named "hq's ADR 0136" as the source of the two-payload-kinds
constraint. It is not in hq. `hq/.dira/entries/dec-0136.md` exists but is
unrelated (a 2026-08-21 design ruling on sire's landing-page bio copy, mark
color, and logo provenance -- nothing to do with fleetd or Jobs). The actual
ADR is `sirerun/sire/docs/adr/0136-fleetd-node-agent-and-where-the-control-plane-runs.md`
("fleetd: a node agent per machine, one protobuf wire, and the control plane
runs with Sire", accepted 2026-09-05). Sire ADR-0137 (kazi-DAG-as-Jobs, the
direct ancestor of today's ruling) already cites it as "ADR 0136", which
matches. Confirmed found; the "hq" attribution in the dispatch is wrong.

**The two payload kinds (ADR-0136 decision 3, dec-0173):** "a prompt
(`claude -p`) and a declared connector tool call. `Job.payload` is a `oneof`
of exactly those two and nothing else... An hq lane run is a prompt Job."

**This switch does not collapse or rename them.** A lane dispatched through
`kazi apply --single-node --in-place` is still a **prompt Job** at the
fleetd/plane boundary: the contract (goal ref + pinned sha + rendered node)
travels through the same channel a natural-language prompt would (ADR-0086
decision 4's "dispatched lane" adapter -- "embeds the node in the prompt
channel the lane already has": the checkpoint `prompt.md`, or the cloud
canary's `TASK_PROMPT`/`TASK_PROMPT_URL`). What changes is what the
in-container entrypoint execs once it unpacks that payload (`kazi apply`
instead of `claude -p`), which is invisible above the container boundary.
No third payload kind is introduced, and the "declared connector tool call"
kind is untouched -- this plan never touches it. Section 3.1 below states
this as a constraint every kazi-side task must hold.

## 1. Kazi-side tasks

Code anchors verified on kazi-org/kazi main at write time (2026-09-05, after
PR #1777 / v1.283.0):

- `--single-node`/`KAZI_SINGLE_NODE` (T73.5, `lib/kazi/cli.ex:2149`
  `single_node_requested?/1`) refuses `--fleet` (`cli.ex:2471`,
  `refuse_single_node_fleet/2`) and a multi-partition `--parallel` apply
  (`cli.ex:3166-3168`, `refuse_single_node_partition/3`) before dispatch, and
  additively stamps `single_node: true` on a one-partition run's `--json`
  result (`cli.ex:3865`, `maybe_stash_single_node/2`). It reads no lane
  contract, no task sha, no render sha, and does nothing about worktree
  indirection. This is the entire footprint of what exists today; everything
  below is new.
- `--in-place` (`cli.ex:163`, `flags[:in_place]`) already exists and already
  bypasses ADR-0065 worktree indirection (`cli.ex:3368`:
  `opts[:in_place] == true or not git_repo?(base_workspace)`). It is a
  general-purpose flag, not lane-specific, and today has no interaction with
  `--single-node` beyond both being ordinary boolean opts.
- `[integration]` landing (push -> PR -> rebase-merge via `gh`, or a local
  rebase-merge; `docs/schemas/run-result.md` "integration -- serial landing
  verdict", ADR-0065 decision 2) exists but is **structurally absent for
  `--in-place` runs**: "present only when a landing was attempted: the run
  was worktree-isolated (not `--in-place`, a git workspace)... absent on
  in-place runs". Since lane mode mandates `--in-place` (the container's own
  clone IS the workspace, no worktree indirection), a converged lane-mode run
  today has **no path** to push a branch or open a PR from inside kazi.
- `kazi apply --check --json` (`cli.ex:10298-10382`, `check_goal/3` /
  `check_result_json/3`) is observe-only: `{schema_version, goal_id,
  mode: "check", status: "pass"|"fail", dispatched: false, predicates:
  [{id, verdict, evidence?}]}`. It is undocumented outside inline code
  comments and `@flag_docs` -- there is no `docs/schemas/check-result.md`.
  Today's hq `entrypoint.sh` calls it **after** `claude -p` exits, purely to
  enrich `state.json`'s `verdicts` field; the actual done/blocked/checkpointed
  status still comes from what the agent itself wrote.

### 1.1 `--single-node --in-place` as a first-class lane entrypoint mode

Reads the pinned task sha and rendered-node sha from a lane contract. Based
on the actual `CONTRACT.md` shape (`jobs/session-container/CONTRACT.md` +
`lane.sh`'s `contract_meta` python block): today's `contract.json` is
`{schema_version: 1, run_id, task, task_sha, goal, predicates: [...],
budget, predicted, history: [...], memory_gate}` -- note it carries **no
render-sha field today**; ADR-0086 decision 5(b) requires one ("the
dispatcher records the rendered content's sha256 in the lane contract beside
the task sha") but nothing produces it yet on either side. That gap is
`TKE.2` below plus hq dependency `D2`.

- [ ] TKE.1 Lane-contract input + workspace/task-sha match. A new
  `--lane-contract <path>` flag (mirroring `--single-node`'s CLI-flag-or-env
  pattern, T73.5 precedent: also readable from `KAZI_LANE_CONTRACT`, since
  ADR-0086's lane adapter passes dispatch inputs by contract file + env, not
  a CLI rewrite) parses a contract.json-shaped file and requires `task_sha`.
  Before any predicate observation or harness dispatch, compare
  `git -C <workspace> rev-parse HEAD` against `task_sha`; on mismatch, refuse
  the same way `refuse_single_node_fleet/2` does (exit non-zero; `--json`
  carries `"reason": "lane_contract_violation"` with a `"kind":
  "wrong_task_sha"` sub-field naming both shas; human output mirrors it on
  stderr, `error:`-prefixed). On match, proceed exactly as today. Only
  meaningful in combination with `--single-node --in-place`; without those
  two, `--lane-contract` is accepted but inert (documented, not silently
  ignored -- a lone `--lane-contract` with no `--single-node` is itself a
  refusal, since a contract implies a governed lane and a governed lane is
  always single-node).
  Owner: pool  Est: 3h  kind: agent  verifies: [cli]  deps: []
  acc: [RED today: `KAZI_LANE_CONTRACT=<path> kazi apply <goal>
  --single-node --in-place` against a workspace whose checked-out HEAD
  differs from the contract's `task_sha` dispatches the harness normally --
  no check exists. GREEN: the same invocation refuses before any harness
  dispatch (a spy/mocked dispatcher proves zero calls), exits non-zero, and
  `--json` carries `reason: "lane_contract_violation"`, `kind:
  "wrong_task_sha"`; a fixture whose HEAD matches `task_sha` proceeds
  unchanged; `--lane-contract` absent is byte-identical to today.]

- [ ] TKE.2 Render-freshness check against the contract's `render_sha256`
  (ADR-0086 decision 5(b)). When the lane contract carries `render_sha256`,
  re-render the node (reusing ADR-0086 decision 3's pure `render(goal.toml,
  scope root, observe result) -> node content` -- E72 T72.3's renderer) from
  the current goal-file plus one observe pass, sha256 it, and compare before
  the first harness dispatch. Note this is a genuine extension of ADR-0086
  decision 5(b), not a restatement: that decision names `kazi apply --check`
  (observe-only) as the verification call the dispatcher can run any time;
  this task additionally gates the **grind** path (`apply` without
  `--check`) itself on the same check, so a lane's own convergence run
  refuses to start against a stale render rather than only being checkable
  after the fact. Worth chief-architect's awareness as a small ADR-0086
  extension point, not a contradiction of it.
  Owner: pool  Est: 3h  kind: agent  verifies: [cli, infrastructure]
  deps: [TKE.1]
  acc: [RED today: nothing in the `apply` (grind) path reads or checks a
  render sha at all -- a lane whose embedded node has gone stale relative to
  `goal.toml` (edited between render-at-dispatch and container start)
  dispatches undetected. GREEN: a lane-contract fixture whose `render_sha256`
  matches the freshly re-rendered node's sha256 proceeds; one whose
  `render_sha256` does not match refuses before any harness dispatch with
  `reason: "lane_contract_violation"`, `kind: "stale_render"`, naming
  expected vs actual sha256; absent `render_sha256` in an otherwise-valid
  contract is a distinct, clearly-worded refusal (fail closed, not silently
  skipped), so `D2` landing late is loud, not invisible.]

### 1.2 The `[integration]` contract and a resumable apply

Today, per the actual hq scripts read: session-container's gh-none lanes
(the default for every repo row -- `sire`, `hq`, and the `*` fallback are
all `none`) **never** push or open a PR from inside the container; the host's
`lane.sh` `host_publish` does it after exit, using the host's own `gh`/git
identity, specifically because dec-0768 keeps GitHub credentials out of the
container entirely. Separately, sire's dgx-canary lane (a different hq job,
targeting only `sirerun/sire`) **does** push and open its own PR from inside
the container via the agent's own `claude -p` session, using a minted
`GH_TOKEN`, with an installed `commit-msg` hook enforcing a `Plan-row:
<TASK_ID>` trailer that sire's own Intake check requires. Neither script
today has a "re-read review comments and continue" resume loop.

**Design decided (chief-architect ruling, 2026-09-05 --
`hq/jobs/session-container/kazi-entrypoint-ruling-2026-09-05.md`, folded in
full at 3.2): mode (B) everywhere, one shape for every lane.** kazi computes
the integration action (branch name, `Plan-row`/`Kazi-Goal` trailer value,
PR title/body, base) and hands it to an `--integration-command` hook. kazi
never runs `git push` or `gh pr create` in lane mode and never holds a
GitHub credential -- not for session-container, not for dgx-canary/AWS. The
publisher stays whoever already holds the credential: host-side `lane.sh
host_publish` for session-container (dec-0768's `gh none` is unchanged), and
`entrypoint.sh` with its already-minted `GH_TOKEN` for dgx-canary/AWS
(unchanged mechanism, now driven by kazi's computed action instead of the
agent's own ad hoc git usage). TKE.3/TKE.4 below reflect this as a decided
design, not an open choice.

- [ ] TKE.3 In-place PR-opening via an injectable `--integration-command`
  hook -- **kazi never calls `git push`/`gh pr create`/`git commit` itself
  in lane mode, and never holds a GitHub credential** (decided design, 3.2).
  Add an in-place path that, on convergence with commits ahead of the
  declared base and `[integration]` configured for `pr`/`merge` mode,
  computes a structured "integration action" -- base ref, task branch (the
  currently checked-out branch; no synthesized partition branch, since there
  is no worktree), PR title, PR body, and the trailer value (TKE.4) -- and
  invokes `--integration-command <path>` (or `KAZI_INTEGRATION_COMMAND`),
  passing that action as structured input (e.g. JSON on stdin) and nothing
  else. This is the **only** in-place integration path lane mode has; there
  is no "kazi does it directly" mode to fall back to. The hook is the one
  place git-level mechanics happen -- in practice `entrypoint.sh` invoking
  host-side `lane.sh`'s `host_publish` logic for session-container (gh-none,
  unchanged), or `entrypoint.sh` itself using its already-minted `GH_TOKEN`
  for dgx-canary/AWS. kazi reads the hook's own result (success/failure, and
  on success a PR number/merge-commit) back from its stdout/exit code and
  populates the terminal result's `integration` object (`landed`, `base`,
  `task_branch`, `refs`) from it -- kazi never invents these values itself.
  When `[integration]` wants `pr`/`merge` under lane mode but no hook is
  configured, refuse clearly (reason `lane_integration_hook_missing`) rather
  than silently converging with nothing landed.
  Owner: pool  Est: 4h  kind: agent  verifies: [cli, infrastructure]
  deps: [TKE.1]
  acc: [RED today: `kazi apply <goal> --single-node --in-place` against a
  fixture with commits ahead of its base and `[integration]` mode `pr`
  converges, and the terminal `--json` result carries no `integration`
  object -- no hook mechanism exists to invoke at all. GREEN: with
  `--integration-command <stub-script>` set, on convergence the stub is
  invoked exactly once with the computed action (base, task branch, PR
  title/body, trailer value) as structured input; a subprocess spy proves
  kazi itself invokes **no** `git push`/`gh`/`git commit` command directly
  anywhere in this path -- only the configured hook; the stub's own
  recorded success output (a canned PR number/merge-commit) populates the
  terminal result's `integration` object (`landed: true`, `refs.pr`, ...);
  a stub that reports failure yields `integration.landed: false` with the
  surviving task-branch name still reported (nothing lost). Without
  `--integration-command` set, the same fixture refuses with reason
  `lane_integration_hook_missing` instead of converging silently with no
  integration attempted.]

- [ ] TKE.4 Trailer value computation for the integration action (TKE.3).
  Under lane mode, the structured action kazi hands to
  `--integration-command` carries a trailer field identifying the task --
  kazi computes the VALUE only; stamping it onto an actual commit is the
  hook's git-level mechanics (decided design, 3.2), not kazi's. Default:
  reuse the literal `Plan-row: <id>` key sire's own Intake gate already
  checks for, using the contract's task id when present (so a kazi-driven
  sire lane keeps passing sire's existing `check-row-trailer.sh`-style gate
  unmodified); fall back to `Kazi-Goal: <goal-id>` when the contract carries
  no sire-style task id (the generic hq session-container case, which has no
  `Plan-row` convention of its own today).
  Owner: pool  Est: 1.5h  kind: agent  verifies: [cli]  deps: [TKE.3]
  acc: [RED today: no mechanism computes or carries a task-identifying
  trailer value anywhere in kazi's output. GREEN: a fixture with a
  sire-style task id in its contract asserts the stub `--integration-command`
  hook receives `{"trailer": "Plan-row: <id>", ...}` in the structured
  action; a fixture with no task id (goal id only) asserts the hook receives
  `{"trailer": "Kazi-Goal: <goal-id>", ...}` instead; a subprocess spy
  proves kazi itself makes zero `git commit`/`git config` calls in lane mode
  -- computing the value and stamping it are different steps, and only the
  first is kazi's.]

- [ ] TKE.5 Resume handle: a lane contract (or `--resume-pr <ref>`) may name
  an already-open PR/branch to continue against. Persist that reference the
  same way kazi already persists a run to its read-model, so a later
  invocation against the same goal is recorded as continuing the same
  logical task rather than starting an unrelated fresh one.
  Owner: pool  Est: 3h  kind: agent  verifies: [cli, infrastructure]
  deps: [TKE.3]
  acc: [RED today: kazi's CLI/contract vocabulary has no field naming an
  open PR to resume; two `kazi apply` invocations against the same goal are
  indistinguishable in the read-model as "same task, later round" vs
  "unrelated re-run". GREEN: invocation 1 (fresh contract, no `resume_pr`)
  converges and opens PR #N (via TKE.3); invocation 2 (a fresh container
  fixture, new task_sha at the tip of PR #N's branch, contract naming
  `resume_pr: N`) is provably recorded in the read-model as continuing the
  same lineage as invocation 1 (a shared run-lineage id), not as a
  disconnected new run; a contract naming a `resume_pr` that does not exist
  (or is already merged/closed) refuses clearly rather than silently
  starting fresh.]

- [ ] TKE.6 Review-comment ingestion as new grind input, read from the
  contract, not fetched by kazi. Consistent with "kazi never holds a GitHub
  credential" (decided design, 3.2): kazi does not call `gh api`/`gh pr
  view` itself -- whoever already holds the credential and composes the
  resume dispatch (host-side `lane.sh` for session-container, or
  `entrypoint.sh` for dgx-canary/AWS) fetches the resume PR's unresolved
  review comments and writes them into an optional `review_comments` array
  on the lane contract (or a sibling file the contract references) before
  kazi ever runs. TKE.6 is kazi's read-and-render half only: when the
  contract carries `review_comments`, render them into the dispatch prompt
  as a new, clearly labeled context section, parallel to the existing
  optional `attempt_ledger`/`memory_recall` layers
  `docs/schemas/run-result.md` documents. (Note for D1/D2: the hq-side
  composer that populates `review_comments` is part of what those
  dependency rows need to build; not specified here.)
  Owner: pool  Est: 3h  kind: agent  verifies: [cli, infrastructure]
  deps: [TKE.5]
  acc: [RED today: kazi's grind loop has no context layer for GitHub PR
  review comments, and no contract field carries them. GREEN: a resume
  fixture whose contract carries one `review_comments` entry shows that
  comment's text in the next dispatch's assembled prompt, in its own labeled
  section; a contract with an empty or absent `review_comments` omits the
  section entirely (byte-identical to a fresh dispatch's prompt shape); a
  subprocess spy proves kazi makes zero `gh`/network calls to fetch review
  state itself.]

### 1.3 A stable, machine-readable Job-outcome shape

**Assessment: `--check --json` is not the right candidate, and is not
sufficient as-is.** It was built for a caller that dispatched an agent
itself and wants a single after-the-fact pass/fail snapshot
(`mode: "check"`, `dispatched: false` hardcoded, `status` is a bare
`pass`/`fail` boolean with no `stuck`/`over_budget`/`error`/`tampered`
granularity, and no `usage`/`economy`/`integration`). Once kazi itself is the
dispatched entrypoint (running the full grind loop, not just observing), the
`dispatched: false` field would be actively wrong for that use, and the
richer status vocabulary the dispatcher actually needs to distinguish
"needs a human" from "has resumable progress" from "genuinely done" does not
exist on this schema at all. **The right base is `apply --json`'s full
terminal result** (`docs/schemas/run-result.md`: `status` in `converged` /
`stuck` / `over_budget` / `error` / `tampered`, plus `integration`, `usage`,
`economy`, and the existing `single_node` marker) -- but even that needs one
additive field, because kazi's status vocabulary and hq's Job-outcome
vocabulary (`DONE`/`REFUSED`/`BLOCKED`/`CHECKPOINTED`, `CONTRACT.md`) do not
line up 1:1, and today's `integration` object is structurally absent for
`--in-place` runs (Section 1.2), which is exactly the shape lane mode always
uses.

- [ ] TKE.7 Additive `job_outcome` field. `apply --json`'s terminal result
  gains an optional `job_outcome` string -- `done`, `blocked`,
  `checkpointed`, or `refused` -- computed the same principled way
  `next_action` already is (a pure function of existing fields, no new
  semantics invented ad hoc): `status: converged` with nothing to land or a
  successful landing -> `done`; `status: converged` with `integration.landed:
  false` (a resumable PR/branch exists) -> `checkpointed`; `status: stuck` or
  `over_budget` with commits ahead of the base -> `checkpointed`; the same
  two statuses with zero committed progress -> `blocked`; `status: error` or
  `tampered` -> `refused`. Present only when the run was lane mode
  (single_node + in_place + a lane contract, Section 1.1); absent otherwise,
  byte-identical to today for every other caller.
  Owner: pool  Est: 2.5h  kind: agent  verifies: [cli]  deps: [TKE.3]
  acc: [RED today: `apply --json`'s `status` enum has no declared mapping
  onto hq's exit-code vocabulary; a dispatcher must invent and hand-maintain
  that mapping itself. GREEN: a table-driven test over every
  (status, integration.landed, has_commits) combination asserts the
  documented `job_outcome`; a non-lane-mode run's result carries no
  `job_outcome` key at all.]

- [ ] TKE.8 Close two documentation gaps this switch depends on: (a)
  `docs/schemas/run-result.md`'s `integration` section documents the
  in-place case TKE.3 adds as populated, with a worked example; (b) a new
  `docs/schemas/check-result.md` documents `--check --json`'s existing shape
  (`mode`, `status`, `dispatched`, `predicates[]+evidence`) against
  `check_result_json/3`, closing a pre-existing ADR-0034 gap independent of
  this switch (it has never had a dedicated schema doc).
  Owner: pool  Est: 2h  kind: agent  verifies: [docs]
  deps: [TKE.3, TKE.7]
  acc: [E29's doc-coverage check counts `check-result.md` and the updated
  `integration` section as present; a reader following only
  `docs/schemas/*.md` (no source read) can correctly predict the shape of
  both a lane-mode `integration` object and a `--check --json` result.]

**Kazi-side total: 8 tasks, ~22h estimated** (3 + 3 + 4 + 1.5 + 3 + 3 + 2.5 + 2).

## 2. hq-side (and one sire-side) dependencies -- named, not owned here

Per chief-architect's instruction, these are named for sire-planner to mint
as real rows in the appropriate repo (hq or sire), not specified in this
plan's task-shape detail. Each names what it blocks/is blocked by among the
kazi-side tasks above.

- **D1 -- `entrypoint.sh` classification + dispatch switch (hq,
  `jobs/session-container/entrypoint.sh`).** Add a "contract-bearing vs
  goal-less" check. Concretely, per what's actually in the scripts: every
  `lane.sh`-dispatched session-container lane is **already**
  contract-bearing today -- `--task` is unconditionally required (dec-0741;
  "the T6.10 prompt-only exemption is spent") and the contract's front
  matter must resolve a `goal:` + non-empty `predicates:` (ADR 005) before
  dispatch even happens. So the actual "goal-less" case left is narrower
  than it first sounds: a direct `run-session.sh` invocation with no
  `--task` (the raw `-- claude args` / bare `claude --version` probe path).
  Sire's separate dgx-canary lane (a different job entirely, D5) is not this
  D1's concern -- `aws-run-canary.sh` today ignores any front matter in
  `docs/tasks/<id>.md` and always composes a free-form prompt, regardless of
  whether the file happens to carry `goal:` (D5's correction: some already
  do). D5, not D1, is where that distinction is drawn. For the
  contract-bearing case, `entrypoint.sh` execs `kazi apply "$goal"
  --single-node --in-place --lane-contract /checkpoint/contract.json`
  instead of `claude -p "$(cat prompt.md)" ...`; for the goal-less case it
  keeps `claude -p` unchanged. Also, since kazi never holds a GitHub
  credential in lane mode (decided design, 3.2), D1 owns supplying
  `--integration-command` (a wrapper invoking `host_publish`-equivalent
  logic or `entrypoint.sh`'s own minted-token path per D4) and, for a
  resumed dispatch, composing the optional `review_comments` array TKE.6
  reads (fetched with whatever credential `entrypoint.sh`/`lane.sh` already
  holds, before kazi runs). Blocked by TKE.1 (needs `--lane-contract` to
  exist) and TKE.7 (needs `job_outcome` to replace entrypoint's current
  post-hoc, agent-self-reported done/blocked/checkpointed inference). Full
  behavioral parity with today's lane also wants TKE.2/3/4/5/6, but D1's
  minimal version only strictly needs TKE.1 + TKE.7.

- **D2 -- `lane.sh` contract composition: add `render_sha256`, stop
  assembling a `claude -p`-shaped `prompt.md` body for contract-bearing
  lanes (hq, `jobs/session-container/lane.sh`).** Confirmed required by
  chief-architect's review (2026-09-05 ruling), no hedge: this is a hard
  gap, not a maybe. Today's `contract_meta`
  python block emits no render field at all. Per ADR-0086 decision 5(b), add
  a host-side render step at the pinned `base_sha` (calling into kazi's
  existing `kazi plan render` machinery per ADR-0086 decision 4's dispatcher
  adapter) and store its sha256 as `render_sha256` beside `task_sha` in
  `contract.json`. `prompt.md`'s current natural-language assembly (lane
  header + task text + exit-code table + result-record instructions, written
  for `claude -p` to consume verbatim) is either dropped for contract-bearing
  lanes or repurposed purely as the embedded-node carrier ADR-0086 decision 4
  describes. Blocks TKE.2's end-to-end (integration) verification and D1's
  contract-bearing branch; not blocked by anything kazi-side (TKE.2's own
  unit tests can synthesize a contract fixture without D2 landing first).

- **D3 -- `entrypoint.sh`'s state.json mapping moves from
  self-observed-post-hoc to kazi's own `job_outcome` (hq,
  `jobs/session-container/entrypoint.sh`).** Today `entrypoint.sh` calls
  `kazi apply "$goal" --workspace "$WORK" --check --json` only *after*
  `claude -p` exits, solely to enrich `state.json`'s `verdicts` field --
  the actual done/blocked/checkpointed status still comes from what the
  agent itself wrote. Once kazi is the entrypoint, this step shrinks to:
  read kazi's own terminal result's `job_outcome` and map it 1:1 onto
  `state.json.status`, closing a real trust gap `CONTRACT.md` itself warns
  about ("the exit code alone never makes a lane DONE") -- kazi's own
  converged-and-landed verdict becomes authoritative instead of an
  LLM-authored self-report. Blocked by TKE.7; blocks nothing kazi-side.

- **D4 -- wire `--integration-command` to the existing publisher on each
  path; dec-0768 stands, unchanged (hq, `lane.sh` + `run-session.sh` +
  `entrypoint.sh` on both the session-container and dgx-canary/AWS jobs).**
  **Decided (chief-architect ruling, 2026-09-05): dec-0768 is not reopened.**
  `gh none` stands for every hq repo row; no repo flips to `gh mint`, and
  kazi never gains or needs a GitHub credential, in either the session-
  container or the dgx-canary/AWS path -- both already have their own
  credential today and neither needs a new one. D4's actual scope, now that
  the design is decided (3.2), is narrower than a security-model change: for
  session-container, `entrypoint.sh` supplies `--integration-command`
  pointing at a wrapper that performs (or defers to the host's) `lane.sh
  host_publish` push/PR-create logic, unchanged credential-wise; for
  dgx-canary/AWS, `entrypoint.sh` supplies a hook that performs the same
  push/`gh pr create` it already does today with its minted `GH_TOKEN`, now
  driven by kazi's computed action (branch, trailer, title, body) instead of
  the agent's own ad hoc git usage plus the installed `commit-msg` hook.
  The AWS in-container token itself is a pre-existing, already-accepted
  exception under its own prior rulings (dec-0544 etc.), not something this
  plan introduces or expands; it is a future direction, out of this plan's
  scope, that it converges to host-side publishing once fleetd Jobs carry
  the ADR-0136 per-Job token -- noted here, not specified. Blocked by
  nothing (the design is decided); blocks D1's dispatch line only in the
  sense that D1 needs a working `--integration-command` target to point at.

- **D5 -- `aws-run-canary.sh` / sire's dgx-canary lane: goal-ref+sha instead
  of a composed prompt, per-row, not universal (hq
  `jobs/dgx-canary/aws/aws-run-canary.sh`, and sire's `docs/tasks/*.md`).**
  **Corrected (chief-architect ruling, 2026-09-05): my original premise --
  "sire's task format has no kazi goal-file concept at all" -- was partly
  wrong.** Verified directly on sire `origin/develop`: 6 of 84
  `docs/tasks/*.md` files already carry `goal:` front matter (e.g.
  T-FLEETD.1 -> `goals/t-fleetd-1.goal.toml`, plus a `predicates:` field),
  per sire's own ADR-005/dec-0741. The format exists; adoption is per row,
  not blocked. D5 is **not blocked**. The rule: `aws-run-canary.sh` reads
  `goal:` from the task contract's front matter -- present means dispatch as
  a kazi single-node run at the pinned sha (mirroring D1's session-container
  branch); absent means fall back to a prompt Job via `claude -p`, already
  permitted by dec-0849 for goal-less lanes. Backfilling `goal:` onto the
  other 78 undispatched rows is a sire-planner planning row of its own, not
  a blocker this D5 names. Blocks nothing kazi-side; blocked by nothing.

- **D6 -- kazi installed in the AWS canary image (`jobs/dgx-canary/
  sire.Containerfile`).** Confirmed by reading it: unlike
  `jobs/session-container/Containerfile` (which already pins and
  sha256-verifies a kazi release binary, `KAZI_VERSION=v1.275.2`),
  `sire.Containerfile` installs no kazi at all. Add the same pinned-binary +
  sha256-verify stanza. Can land as pure image prep any time -- D5 is not
  blocked on a format decision (corrected above), but its `goal:`-present
  branch has nothing to exec without this landing first, so D6 should land
  no later than D5's `entrypoint.sh` switch.

## 3. Ordering, constraints, and the one integration test

### 3.1 Constraint conformance

- **No fleet or partitions inside a container, ever.** Nothing in Section 1
  touches `Kazi.Fleet`/`Kazi.Partition`/`Kazi.Scheduler` fan-out; TKE.1's
  refusal is additive on top of T73.5's existing single_node refusal, not a
  replacement of it.
- **The two ADR-0136 payload kinds are unchanged** (Section 0): this switch
  stays entirely inside the existing "prompt" kind's container-side
  execution; the "declared connector tool call" kind is untouched.

### 3.2 Design decisions (chief-architect ruling, 2026-09-05)

Both items below were open judgment calls in the version of this plan
chief-architect reviewed; both are now decided. Full ruling text:
`hq/jobs/session-container/kazi-entrypoint-ruling-2026-09-05.md`. Folded in
here and reflected in TKE.3/TKE.4/TKE.6 and D4 above.

**Decision 1 -- in-place PR-opening mode: (B) everywhere, one shape for
every lane.** kazi computes the integration action (branch name, `Plan-row`
trailer value, PR title/body, base) and hands it to an
`--integration-command` hook. kazi never runs `git push` or `gh pr create`
in lane mode and never holds a GitHub credential. Mode (A) -- kazi calling
`git`/`gh` directly, reusing `Kazi.Scheduler.Integration`'s existing
`--parallel`-path code -- is **not** offered in lane mode, even though that
code already exists and already shells to `git`/`gh` for the non-lane path;
lane mode gets a distinct, hook-only path instead. Publisher = whoever holds
the credential today: session-container's host `lane.sh host_publish` after
container exit (dec-0768's `gh none` unchanged); dgx-canary/AWS's
`entrypoint.sh` with its already-minted `GH_TOKEN` (unchanged). Why: honors
dec-0849's "git plumbing stays in entrypoint.sh" literally, keeps kazi
credential-free everywhere, and both publishers already exist and need no
new credential machinery -- only a new input shape (kazi's computed action)
in place of what each composed for itself before.

**Decision 2 -- dec-0768 is not reopened.** Nothing about the container
credential surface reverses. `gh none` stands for every hq repo row; no
repo flips to `gh mint` for this switch. The dgx-canary/AWS in-container
token is the pre-existing, already-accepted exception under its own prior
rulings, not something this switch introduces or expands -- it converges to
host-side publishing once fleetd Jobs carry the ADR-0136 per-Job token
(a future direction, out of this plan's scope; noted, not specified). No
founder sign-off is needed for this switch specifically, since it changes
no credential surface.

### 3.3 Ordering (dependency-respecting)

```
Wave KE-A (parallel, kazi):      TKE.1, TKE.7*, TKE.8a (doc-only half of TKE.8:
                                  check-result.md, no code dependency)
Wave KE-B (kazi):                TKE.2   [needs TKE.1; end-to-end proof needs D2]
Wave KE-C (kazi):                TKE.3   [needs TKE.1; implements the decided
                                  (B)-everywhere hook design, 3.2]
Wave KE-D (parallel, kazi):      TKE.4, TKE.7 (full form)   [both need TKE.3]
Wave KE-E (kazi):                TKE.5   [needs TKE.3]
Wave KE-F (kazi):                TKE.6, TKE.8b (integration-doc half)   [need TKE.5, TKE.3+TKE.7]

hq/sire side (sire-planner mints, tracked in hq/sire repos):
  D2  -- independent of kazi; should land close to TKE.2 for real coverage
  D6  -- independent of everything; pure image prep, land whenever
  D1  -- blocked by TKE.1 + TKE.7 (minimal) / TKE.1-6 (full parity)
  D4  -- blocked by nothing (design decided, 3.2); needed by D1/D5's
         --integration-command target
  D3  -- blocked by TKE.7
  D5  -- not blocked (corrected, 3.2); its goal:-present branch has nothing
         to exec until D6 lands
```

*TKE.7 appears twice above: its acceptance table can be written and
unit-tested against synthetic `status`/`integration`/commit-count inputs in
Wave KE-A without TKE.3 existing yet, but it cannot be exercised
end-to-end (a real `integration.landed` value from a real in-place run)
until TKE.3 lands in Wave KE-C -- hence "full form" in Wave KE-D.

### 3.4 The one integration test

**Location:** hq repo, `jobs/session-container/lane-kazi-entrypoint-
selftest.sh`, extending the existing `lane-selftest.sh`/`run-session-
selftest.sh` hermetic-test pattern lane.sh's own comments already reference
(a fixture repo, a stub bare git remote, no real podman network egress).
Owned by whichever hq-side task lands D1 -- a switch of this consequence
ships with its own proof in the same change, not as a follow-up.

**Fixture:**
- A scratch git repo, freshly created by the selftest (mirroring how
  `run-session-selftest.sh` already fabricates a fixture repo), containing:
  - `.kazi/goals/fixture.goal.toml`: one cheap, deterministic predicate that
    starts FAILING (a `custom_script` predicate checking for a marker the
    fixture's hermetic fake-harness seam can be told to produce -- the same
    test-double seam T73.5's own suite uses to drive `Kazi.CLI.run/2`
    hermetically, so the test needs no live LLM call), and an
    `[integration]` block configured for `pr` mode.
  - `docs/tasks/fixture-lane.md`: valid ADR-005 front matter naming that
    goal and predicate.
- A stub `--integration-command` script standing in for the real
  `host_publish`/`entrypoint.sh` hook (decided design, 3.2): it receives
  kazi's computed action on stdin, pushes to a stub bare git repo standing
  in for `origin`, calls a stub `gh pr create`, and prints back a canned
  success result (PR number, merge commit) for kazi to read. A separate
  canned `review_comments` fixture file stands in for what D1's
  contract-composer would have fetched via `gh pr view --json comments`
  before a resume dispatch (TKE.6 reads it from the contract; kazi itself
  makes no `gh`/network call in this test, matching the decided design). No
  network, no real GitHub credential anywhere in the test -- consistent
  with the project's existing hermetic-test philosophy.

**Stages and what each proves:**

1. **Refusal proof (negative control).** Dispatch the fixture with a
   deliberately wrong `task_sha` (or a stale `render_sha256`) in
   `contract.json`. Asserts: `entrypoint.sh` exits 1 (REFUSED) before any
   harness dispatch is attempted (the fake-harness seam records zero calls).
   Proves TKE.1/TKE.2's pre-dispatch refusal actually gates the real lane
   path, not just kazi's CLI in isolation.
2. **Convergence + PR proof.** Dispatch with a correct contract. Asserts:
   kazi's grind loop converges the fixture predicate via the hermetic
   fake-harness seam; kazi invokes the stub `--integration-command` exactly
   once with a structured action carrying the fixture task id's trailer
   value and kazi-generated PR title/body (a subprocess spy proves kazi
   itself calls no `git push`/`gh` command directly); the stub's own push
   (verified against the stub bare remote's refs afterward) and its stub
   `gh pr create` call happen exactly once each, driven by that action.
   Proves TKE.3 + TKE.4 end to end through the real dispatch scripts and the
   decided hook boundary (3.2).
3. **Outcome-mapping proof.** After stage 2, asserts `state.json` reports
   `status: "done"` (mapped from kazi's `job_outcome: "done"`, TKE.7 via
   D3) and the container's own exit code is 0 (`CONTRACT.md` DONE). Proves
   TKE.7's mapping reaches the actual hq exit-code contract, not only
   kazi's own JSON.
4. **Resume proof (second invocation).** The selftest composes a second
   lane contract naming `resume_pr: <the stage-2 PR number>` and carrying a
   canned `review_comments` entry (standing in for what a real D1 composer
   would have fetched with its own credential before this dispatch --
   TKE.6's premise is that kazi never fetches this itself). Asserts: the
   fake-harness seam's captured second-dispatch prompt contains the comment
   text in a distinct labeled section (TKE.6); the read-model records both
   runs under one lineage (TKE.5); a subprocess spy proves kazi makes no
   `gh`/network call anywhere in this stage either.
5. **Negative-space proof.** A direct `run-session.sh` invocation with no
   `--task` (the raw-argv / `claude --version` probe path) still execs
   `claude`, never `kazi` -- proving D1's contract-bearing classification
   does not regress the one remaining goal-less path.

This test needs D1 (the entrypoint switch it exercises), D2 (a real
`render_sha256` for stage 1's negative control to be meaningful against the
actual dispatch path, not a synthesized fixture), and TKE.1 through TKE.7 on
the kazi side to all be in place; it is the acceptance gate for the whole
switch, not a task any single row above owns alone.

## 4. Summary for the record

- Kazi-side: 8 tasks (TKE.1-TKE.8), ~22h estimated.
- hq/sire-side: 6 named dependencies (D1-D6), not specified in task-shape
  detail here -- sire-planner mints the real rows.
- Both design decisions chief-architect ruled on (2026-09-05,
  `hq/jobs/session-container/kazi-entrypoint-ruling-2026-09-05.md`) are
  folded in as decided, not open: (1) mode (B) everywhere -- kazi computes
  the integration action and hands it to an injectable
  `--integration-command` hook, never calling `git`/`gh` itself in lane
  mode; (2) dec-0768 is not reopened -- `gh none` stands for every repo,
  kazi never holds a GitHub credential, and the dgx-canary/AWS in-container
  token is an unrelated pre-existing exception, not something this switch
  expands. TKE.3/TKE.4/TKE.6, D4, and the integration test (3.4) all reflect
  this; TKE.6 was additionally corrected on my own read of decision 2's
  consequence (kazi holding zero GitHub credential rules out kazi calling
  `gh api` for review comments too, not only `gh pr create`) -- review
  comments now arrive as a `review_comments` field on the lane contract,
  composed by whoever already holds the credential, not fetched by kazi.
- D2 (lane.sh must emit `render_sha256`) is confirmed required, no hedge.
- D5's premise is corrected: sire's `docs/tasks/*.md` format already has a
  `goal:`/`predicates:` front-matter convention on 6 of 84 rows (verified by
  chief-architect on `origin/develop`); D5 is not blocked, only per-row
  adoption remains (sire-planner's row, not named here).
- ADR 0136 is a sire ADR (`sirerun/sire/docs/adr/0136-...md`), not hq's;
  found and read; chief-architect confirmed the correction was right. Its
  two payload kinds (`prompt` / `declared connector tool call`) are
  unchanged by this plan -- Section 0 states why.

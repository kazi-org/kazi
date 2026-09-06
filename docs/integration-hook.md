# The `--integration-command` hook contract (TKE.3)

`docs/plans/E-KAZI-ENTRYPOINT.md` §1.2, decided design "mode (B) everywhere"
(chief-architect ruling 2026-09-05, folded in full at plan §3.2).

## Why this exists

A governed lane (`--single-node --in-place`) has no separate task worktree to
land converged work from -- the workspace **is** the edit site. kazi **never**
runs `git push`, `gh pr create`, or `git commit` itself in lane mode, and never
holds a GitHub credential. When a lane's `[integration]` block wants `pr` or
`merge` mode and the run converges with commits ahead of the declared base,
kazi computes a structured **integration action** and hands it to an
injectable hook -- `--integration-command <path>` (or
`KAZI_INTEGRATION_COMMAND`) -- which is the **only** place git-level mechanics
happen for an in-place run. The hook is typically a thin wrapper that defers
to whoever already holds the credential: the host's `lane.sh host_publish`
logic for a session-container lane (`gh none` unchanged, dec-0768), or
`entrypoint.sh`'s own minted `GH_TOKEN` for a dgx-canary/AWS lane.

This is a **wholly distinct, hook-only** code path from
`Kazi.Scheduler.Integration`'s existing git/gh-calling code (the non-lane
`--parallel` landing path) and from the loop's own mid-run `:integrate` action
(`Kazi.Actions.Integrate`, ADR-0055, ordinarily fired when a goal declares
`[integration]` and its `landed` predicate hasn't passed yet) -- in lane mode,
kazi disables that mid-run action entirely (the goal's declared predicates
alone gate convergence) and defers *all* landing to this hook, run exactly
once, after convergence.

## When it fires

All of the following must hold:

- The run is **lane mode**: `--single-node --in-place` were both passed.
- The converged goal's `[integration]` block declares `mode = "pr"` or
  `mode = "merge"`.
- The workspace has at least one commit ahead of the declared base (an
  explicit `--base`, else the goal-file's own `[integration] base`, else a
  merge-base guess against the workspace) -- an uncommitted-only fix or a
  fix that needed no new commit leaves nothing to land, and the hook is never
  invoked.

When `[integration]` wants `pr`/`merge` under lane mode but no hook is
configured, the run refuses to silently converge with nothing landed:
`integration.reason` is `"lane_integration_hook_missing"`, exit code 1.

## Invocation

kazi invokes the configured command with the action as a single JSON object
on **stdin**, and nothing else (no CLI arguments beyond the command path
itself). The hook's own stdout must be a single JSON object; everything else
about how the hook does its work (branch naming beyond what the action names,
commit-trailer stamping, push mechanics, PR/merge API calls) is the hook's
business, not kazi's.

## stdin -- the integration action (kazi → hook)

```json
{
  "schema_version": 1,
  "goal_id": "my-goal",
  "mode": "pr",
  "base": "a1b2c3d4e5f6...",
  "task_branch": "task/my-goal",
  "trailer": "Kazi-Goal: my-goal",
  "pr_title": "my-goal: converged via kazi",
  "pr_body": "Converged by `kazi apply --single-node --in-place`.\n\nGoal: my-goal\nBase: a1b2c3d4e5f6...\nTask branch: task/my-goal\n\nKazi-Goal: my-goal\n"
}
```

| Field            | Type   | Meaning |
|------------------|--------|---------|
| `schema_version` | number | This schema's version (currently `1`). |
| `goal_id`        | string | The converged goal's id. |
| `mode`           | string | The goal's declared `[integration] mode` -- `"pr"` or `"merge"` (this hook is never invoked for `"none"`/`"commit"`/`"branch"`). |
| `base`           | string | The base ref/sha the work should land onto -- kazi's own computed value, never a guess the hook has to make. |
| `task_branch`    | string | The lane's currently checked-out branch (there is no separate worktree in lane mode, so this **is** the edit site's branch). |
| `trailer`        | string | A task-identifying trailer VALUE only -- `"Kazi-Goal: <goal-id>"` today. **TKE.4** (a later task) will prefer `"Plan-row: <id>"` when the lane contract names a sire-style task id; kazi computes the value, stamping it onto a commit/PR is the hook's own git-level mechanics. |
| `pr_title`       | string | A default PR title (`"<goal-id>: converged via kazi"`). The hook may use, extend, or ignore it. |
| `pr_body`        | string | A default PR body naming the goal, base, and task branch, with the trailer appended. The hook may use, extend, or ignore it. |

kazi never invents these values from thin air -- `base`/`task_branch`/`mode`
come straight from the run's own declared/observed state, and `trailer` is
computed the same principled way `next_action` is (no ad hoc guessing).

## stdout -- the hook's result (hook → kazi)

The hook prints **exactly one JSON object** to stdout before exiting, and
kazi's reading of it is strict and self-contained:

Success:

```json
{ "landed": true, "refs": { "pr": 123 } }
```

or, for `merge` mode:

```json
{ "landed": true, "refs": { "merge_commit": "abc123..." } }
```

Failure:

```json
{ "landed": false, "reason": "push rejected: non-fast-forward" }
```

| Field    | Type              | Meaning |
|----------|-------------------|---------|
| `landed` | boolean, required | Whether the hook actually landed the work. |
| `refs`   | object (on success) | Whatever refs the hook's own integrator produced -- `pr`/`merge_commit`, matching the shape `docs/schemas/run-result.md`'s `integration.refs` already documents for the worktree-landing path. |
| `reason` | string (on failure)  | A human-readable failure reason. |

**Exit code + stdout together decide the verdict, never exit code alone:**

- Exit `0` **and** valid JSON with `"landed": true` → the run's terminal
  `integration` object reports `landed: true` with the hook's `refs`.
- Exit `0` **and** valid JSON with `"landed": false"` → `landed: false` with
  the hook's `reason` (defaulting to a generic message if `reason` is
  omitted).
- A non-zero exit code, or stdout that is not valid JSON, is **always** a
  reported failure regardless of what (if anything) the hook printed --
  `landed: false`, `reason` naming the exit code and captured
  stdout/stderr (or naming the JSON parse failure). kazi never crashes on a
  malformed or crashing hook.

In every case kazi's terminal result's `integration` object also carries
`base` and `task_branch` from the ORIGINAL computed action (not from the
hook's stdout) -- see
[`integration` — serial landing verdict](schemas/run-result.md#integration--serial-landing-verdict-adr-0065),
whose shape this in-place path reuses exactly.

## The flag / env var

`--integration-command <path>` or `KAZI_INTEGRATION_COMMAND` (mirroring
`--lane-contract`/`KAZI_LANE_CONTRACT`'s flag-or-env pattern, TKE.1): the flag
wins when both are set. Neither has any effect outside lane mode, or when
`[integration] mode` is `none`/`commit`/`branch`, or when there is nothing
ahead of the base to land.

## Resume handle / run-lineage (TKE.5)

A successful hook reply's `refs.pr` (or `refs["pr"]`) is recorded onto the
landing run's own fleet-registry row (`Kazi.ReadModel.RunRegistry.record_pr_ref/2`,
normalized to a bare number with no leading `#`). That recording is what
makes the PR **resumable**: a later `kazi apply` naming
`--resume-pr <that number>` (or a lane contract's own `"resume_pr"` field --
same CLI-flag-or-env precedence pattern, `--resume-pr`/`KAZI_RESUME_PR`) is
recorded in the read-model under the SAME `lineage_id` as this run, rather
than starting an unrelated fresh one.

kazi verifies a named `--resume-pr` **locally only** -- it never calls
`gh`/the GitHub API (the same "no GitHub credential in kazi, ever, in lane
mode" constraint this hook exists for): it looks up its own registry for a
prior run that recorded landing that exact PR number, and separately checks
(via `git merge-base --is-ancestor`, no network) whether the workspace's
checked-out HEAD already looks merged into the declared base. A `--resume-pr`
naming a PR the registry has never seen, or one that already looks merged,
refuses before any predicate observation or harness dispatch
(`"reason": "resume_pr_invalid"`, `"kind"` one of `"resume_pr_not_found"` /
`"resume_pr_already_landed"`). This is advisory, not a live GitHub truth
check: a PR closed *without* merging is not caught here (that gap is
intentional -- a real GitHub-side check belongs in this SAME hook mechanism,
which already holds the credential, not in a direct `gh` call from kazi).

See `--resume-pr`'s full flag help (`kazi apply --help`) for the exact
refusal shapes.

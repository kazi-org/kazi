# The `[setup]` step (ADR-0088)

A `kazi apply` task worktree is created via `git worktree add`. That worktree
carries no `deps/`, no `_build/`, no `node_modules/` -- nothing in the
worktree-creation or preflight path installs a build tool's dependencies.
Without a declared setup step, every `mix`-backed (or any other
build-tool-backed) predicate fails at t0 for an ENVIRONMENTAL reason
("Unchecked dependencies for environment test ... run mix deps.get"), not a
product reason -- defeating the guarantee that a red predicate at t0 means
kazi has real work to do (concept R3, the vacuous-goal guard).

`[setup]` closes that gap: a declared list of commands the controller runs
ONCE, in the goal's workspace, immediately BEFORE the t0 predicate
observation -- in both `kazi apply` and `kazi apply --check`.

See [ADR-0088](../adr/0088-goal-file-setup-step-precedes-t0-observation.md)
for the full rationale, including why auto-detecting the build tool and
letting the harness provision the workspace implicitly were both considered
and rejected.

## The `[setup]` block

```toml
[setup]
commands = ["mix deps.get", "mix compile"]
timeout_ms = 300000   # optional; per-command hard deadline, default 300000
```

| key | required | meaning |
|---|---|---|
| `commands` | yes | a list of shell command strings, run IN ORDER, each through `sh -c`, in the goal's workspace. Stops at the FIRST failing command. |
| `timeout_ms` | no | per-command hard deadline in milliseconds (default `300000` = 5 minutes). ALWAYS a positive integer -- a setup command can never wait forever any more than the t0 observation itself can (the #1683 treatment). |

An ABSENT `[setup]` block is byte-identical to before this feature
existed: no commands run, no behavior changes. A PRESENT but empty
`[setup]` table (no `commands` key, or `commands = []`) is ambiguous
authoring intent and fails loudly at load, rather than silently no-op'ing
like an absent block does.

## When you need one

Declare `[setup]` whenever a predicate in the goal shells out to a build
tool that needs its dependencies resolved first -- `mix test`, `mix format
--check-formatted`, `npm test`, `cargo test`, and the like all fail with an
environment error (not a real test failure) against an unprovisioned
checkout. A goal made only of predicates with no such dependency (a `git`
command, a static file check, an HTTP probe) needs no `[setup]` block.

```toml
id = "fix-flaky-retry"
mode = "repair"

[scope]
workspace = "."

[setup]
commands = ["mix deps.get"]

[[predicate]]
id = "suite_green"
provider = "custom_script"
cmd = "mix"
args = ["test"]
verdict = "exit_zero"
```

Without the `[setup]` block above, `suite_green` is red at t0 on a fresh
`git worktree` regardless of whether the retry bug is fixed -- the run
converges on nothing, because the predicate never measured the real
behavior. With it declared, `mix deps.get` runs first, and `suite_green`'s
t0 verdict (and every later re-observation) reflects the actual test suite.

## Setup failure is a distinct environment error, never a predicate verdict

A setup command that exits non-zero, cannot be started (missing binary, bad
workspace), or overruns `timeout_ms` STOPS the run before any predicate is
observed and before any harness is dispatched. `kazi apply --json` reports:

```json
{
  "schema_version": 2,
  "goal_id": "fix-flaky-retry",
  "status": "error",
  "error": "goal [setup] step failed before t0 observation (issue #1642): `mix deps.get` exit 1 Output: ** (Mix) Could not resolve dependency ...  — this is an environment/provisioning error, not a predicate result. Fix the setup command (or the goal's declared [setup] commands) and re-run.",
  "next_action": "investigate"
}
```

This mirrors the sibling case ADR-0088 draws on: a t0 observation that
never completes within its startup deadline (issue #1683) is reported as
`{:error, {:startup_deadline_exceeded, ms}}`, never a predicate `:fail` --
both are named, structured INFRASTRUCTURE errors, because a broken
environment is not failing product work (ADR-0002's `:error` vs `:fail`
boundary). No run is registered and nothing is persisted as converged or
failed on a setup error; fix the setup command and re-run.

## `kazi apply --check` runs the same setup step

`kazi apply --check` (the observe-only merge-gate surface, ADR-0026 L1)
performs the identical t0 observation `kazi apply` does, so it runs the
SAME declared `[setup]` step first -- a merge-gate check against a freshly
created worktree is not a false red either.

# Predicate authoring guide

Patterns that read fine on their own but interact badly with a specific kazi
execution mechanism. Each entry names the hazard, why it happens, and the
stable alternative.

## Guard/held-out predicates run in a DETACHED worktree with no branch identity

Clean-tree isolation (ADR-0042 §1, `Kazi.Enforcement.Isolation`) evaluates
every guard and held-out predicate against a throwaway `git worktree add
--detach` checkout, never the agent's real branch checkout — git refuses the
same branch checked out in two worktrees at once, and the goal's real branch
is simultaneously checked out in the primary workspace. Inside that detached
worktree:

* `git rev-parse --abbrev-ref HEAD` returns the literal string `HEAD`, never
  the goal's branch name.
* `git rev-parse '@{u}'` fatals — there is no `branch.<name>.remote` upstream
  config to resolve, regardless of which commit the worktree was created from.

A guard/held-out predicate that asserts branch identity or upstream tracking
via either idiom is therefore structurally unsatisfiable there, independent of
whether the underlying work is correct and pushed (#1709). A non-isolated
(ordinary iterating) predicate is unaffected — it runs against the real
workspace, a real branch checkout, where both idioms resolve unchanged.

**Stable alternative:** kazi threads `KAZI_GOAL_BRANCH` — the goal's real
target branch (`Kazi.Goal.integration_branch/1`) — into an isolated
predicate's execution environment, always. When the base workspace has an
`origin` remote configured, it also threads `KAZI_GOAL_UPSTREAM` as
`origin/<branch>`. Compare against those instead of `@{u}`/`--abbrev-ref
HEAD`, e.g.:

```sh
# instead of: [ "$(git rev-parse --abbrev-ref HEAD)" = 'task/my-goal' ]
[ -n "$KAZI_GOAL_BRANCH" ]

# instead of: git rev-parse '@{u}'
git rev-parse "$KAZI_GOAL_UPSTREAM"
```

A goal-file-declared `:env` entry with the same name overrides the
controller-supplied value (`Kazi.Providers.CustomScript`'s env merge), so an
explicit override is still possible when a predicate needs one.

## A build-tool-backed predicate needs a declared `[setup]` step (ADR-0088)

A `kazi apply` task worktree is a fresh `git worktree` -- it carries no
`deps/`, `_build/`, or `node_modules/`. If any predicate shells out to a
build tool (`mix test`, `mix format --check-formatted`, `npm test`, `cargo
test`, ...), that predicate is red at t0 for an ENVIRONMENTAL reason
("Unchecked dependencies for environment test ... run mix deps.get"), not a
product reason -- red-at-t0 no longer proves the predicate measures real
behavior (issue #1642).

Declare a `[setup]` block naming the provisioning commands to run once, in
the workspace, BEFORE the t0 observation:

```toml
[setup]
commands = ["mix deps.get"]
```

With `[setup]` declared, red-at-t0 means what it is supposed to mean again:
the product is wrong, not that nobody ran `mix deps.get` first. A goal made
only of predicates with no build-tool dependency needs no `[setup]` block.
See [`docs/how-to/setup-step.md`](how-to/setup-step.md) for the full field
reference and the distinct `{:setup_failed, _}` environment-error shape a
failing setup command produces (never a predicate `:fail`).

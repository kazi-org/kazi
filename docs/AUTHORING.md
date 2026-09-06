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

## Stopping the grind model from touching a path or landing a PR: use `[scope]`, not prose

**The dispatch prompt is the ONLY channel the grind model reads.** It never
sees the orchestrating session's own conversation, a strategy doc, or a
human-authored dispatch brief's prose caveats. Two real incidents happened
because that prose caveat was the only place the constraint lived:

  * kazi-org/kazi#1695 — a dispatch brief's prose explicitly excluded
    `docs/plan.md`, `docs/plans/<epic>.md`, and `docs/roadmap.md` as "the
    orchestrator's to edit, after convergence." The grind loop committed a
    change to two of them anyway, as part of its own convergence stack.
  * kazi-org/kazi#1704 — an orchestrating session told its dispatched
    sub-agent, in its own never-seen conversation, not to open a PR. Running
    under `--permission-mode bypassPermissions` with ambient `gh`
    credentials, the sub-agent opened one anyway.

**Stable alternative:** declare the constraint in the goal-file's `[scope]`
table (ADR-0085) — the one channel that actually reaches the grind model, and
the one kazi's own tooling enforces rather than merely hopes is honored:

```toml
[scope]
# Would have caught #1695: excluded from BOTH the guard predicate AND from
# what Kazi.Actions.Integrate will ever land, not just flagged after the fact.
forbidden_paths = ["docs/plan.md", "docs/plans/", "docs/roadmap.md"]

# Would have caught #1704: Kazi.Actions.Integrate refuses to commit, push,
# open, or merge a PR for this goal at all, no matter what the dispatched
# model's own shell access lets it attempt.
no_integration = true

# Best-effort tripwire ONLY — see docs/how-to/scope-write-guard.md. Does not
# by itself replace `no_integration` above; a bypassPermissions dispatch has
# real shell access this cannot revoke.
forbidden_commands = ["gh pr create", "gh pr merge"]
```

`forbidden_paths` and `no_integration` are STRUCTURAL: the controller's own
commit/landing tooling refuses, independent of whether the dispatched model
ever "reads" the constraint at all. `forbidden_commands` is the one exception
— it is advisory detection, documented as such everywhere it appears, never a
claim of prevention. See `docs/how-to/scope-write-guard.md` for the full
authoring reference and `docs/adr/0085-scope-goal-file-forbidden-paths-commands.md`
for the decision.

## `[scope].contract`: a goal cannot write, or land a change to, its own contract (T73.6)

A goal that names its own human-authored acceptance contract file lets kazi
enforce a narrower version of the same worry `forbidden_paths` addresses: the
grind loop should never be able to edit the very document it is being held
to.

```toml
[scope]
write_paths = ["lib/foo/**"]
contract = "lib/foo/contract.ex"
```

Declaring `contract` gets a goal two things, both additive (a goal-file with
no `contract` behaves byte-identically to before this feature):

  * **`kazi lint <goal-file>` fails (non-zero exit) when the goal's own
    `write_paths`/`paths` covers its own `contract`** — the example above
    fails naming both `lib/foo/**` and `lib/foo/contract.ex`; a contract
    declared outside the goal's write scope (`lib/contracts/foo.ex`) passes.
    Unlike the near-duplicate-group-name net, this IS a hard failure —
    `kazi plan lint <roadmap>` runs the fleet-level version alongside the
    existing nesting check, failing when one member's `write_paths` covers
    ANOTHER member's `contract`, naming both goal ids and the shared path.
  * **The contract path is auto-folded into `forbidden_paths`** — the same
    "auto-extend" pattern below extends `forbidden_paths` with every rendered
    `AGENTS.md`/`CLAUDE.md` path — so a commit touching the contract fails
    the same `:scope_forbidden_paths` guard and `Kazi.Actions.Integrate`
    landing refusal a hand-authored `forbidden_paths` entry would.

A goal with a declared scope root and a `contract` also gets a "Contract"
section in its rendered `AGENTS.md`/`CLAUDE.md` node (see "Scope roots and
the AGENTS.md node" below), containing the contract file's raw content, so a
harness working at the goal's scope root reads its contract through the same
walk-up channel it reads the goal's brief and failing predicates through.

**A goal with a declared scope root (ADR-0086) never needs to author its own
rendered node into `forbidden_paths`.** `kazi apply` extends the goal's
EFFECTIVE `forbidden_paths` automatically with every `AGENTS.md`/`CLAUDE.md`
path it renders for that run (T72.6, ADR-0086 decision 5(c)) — a landed
commit touching the dispatch-context node it just handed the agent fails the
SAME `:scope_forbidden_paths` guard a hand-authored entry would. Freshness
enforcement is separate and stricter still: at run start and every observe
pass, an interactive run re-renders the node and byte-compares it against
the worktree's file, terminating `:rendered_node_drift` (fatal, the same
class ADR-0080's `:tampered` is) on any mismatch — so a hand-edit is caught
mid-run, not only at landing. `kazi apply --check --node-sha <sha256>` is
the equivalent one-shot check for a lane's dispatched (non-interactive)
context: it re-renders from the goal-file and fails if the digest no longer
matches.

## Scope roots and the AGENTS.md node

A goal's `[scope].write_paths` (falling back to `[scope].paths`) is more than
a read/write allow-list — it is also where kazi delivers the goal's brief and
failing predicates to whatever harness is working in that directory
(ADR-0086). Two entry points render the same node:

  * `kazi plan render --tree` writes `<scope-root>/AGENTS.md` for every
    scoped goal in a roadmap, so an operator who `cd`s into a goal's
    directory and opens a harness by hand gets the goal's brief through the
    harness's own walk-up convention, not repo-wide `CLAUDE.md`/`AGENTS.md`
    prose.
  * `kazi apply` re-renders the same node before every dispatch, so a
    dispatched agent working under `--cwd <scope-root>` (T72.7; defaults to
    the goal's first declared scope root) reads it too.

**What renders.** `render(goal.toml, scope root, observe result) -> content`
is a pure function of the goal-file and one observe pass: the goal's brief,
its predicate definitions, the currently failing predicates, and their
evidence, under the generated banner ADR-0082 uses. It never reads the host
read-model registry, so any host with the goal-file and the `kazi` binary
reproduces it byte-for-byte. A goal with no declared scope root renders
nothing, and the repo root is never a render target — it holds only repo-wide
convention files.

**What never commits.** The rendered `AGENTS.md` (and the `CLAUDE.md ->
AGENTS.md` symlink `--tree` creates when no `CLAUDE.md` exists) is delivered
as an untracked, ignored file (`.git/info/exclude`, never `.gitignore` —
that would be a tracked edit) — ADR-0086 decision 3. `kazi apply`
automatically extends the goal's effective `forbidden_paths` (ADR-0085) with
every path it renders, so a landed commit touching its own dispatch-context
node fails the same guard a hand-authored entry would (see "Stopping the
grind model from touching a path" above). The generator never edits,
overwrites, or shadows a hand-written file: an existing `AGENTS.md` lacking
the generated banner makes `--tree` fail, naming the path, and an existing
hand-written `CLAUDE.md` is left untouched (the failure message names the
`@AGENTS.md` include line to add by hand) — decision 6.

**Why the node is not an authority.** ADR-0080 seals `goal.toml`, not its
projection: two sealed authorities with no tiebreak is worse than one.
Instead, freshness enforces the derived file — at run start and every
observe pass, an interactive run re-renders and byte-compares against the
worktree's copy, terminating the run with `:rendered_node_drift` (the same
fatal class as ADR-0080's `:tampered`) on any mismatch; `kazi apply --check
--node-sha <sha256>` gives a lane's dispatched context the equivalent
one-shot check. Decision 6's walk-up claim is settled, not asserted: T72.5's
`test/kazi/harness/walkup_test.exs` proved, for each of the two harnesses
this repo drives (claude, codex), that a real filesystem walk-up from the
scope root reads the rendered node — claude via the `CLAUDE.md -> AGENTS.md`
symlink, codex directly via `AGENTS.md` (codex never reads `CLAUDE.md`, so it
needs no symlink). Both harnesses already followed the walk-up correctly;
neither needed the one-line `CLAUDE.md` w/ `@AGENTS.md`-include fallback
decision 6 describes for a harness that doesn't follow the symlink.

**The nesting rule.** Across the goals kazi can see together — a fleet, or
one `--tree` render — scope roots must be disjoint, and each root carries at
most one goal (decision 2). `kazi plan lint` and `kazi plan render --tree`
both refuse otherwise, naming both goal ids and the shared root: with the
walk-up, an agent working in `pkg/foo/bar` reads every ancestor node, so a
goal rooted at `pkg/foo` and a goal rooted at `pkg/foo/bar` would hand the
child's agent the parent's brief too. Nesting with explicit inheritance is a
follow-up ADR, not a v1 behavior.

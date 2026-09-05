# ADR 0088: `[setup]` goal-file block -- a declared provisioning step runs before t0 observation

## Status

Accepted (DECIDED by the repo owner on issue #1642, 2026-08-08; this ADR
records the design for the implementation, T69.12)

## Date

2026-09-05

## Context

A `kazi apply` task worktree is created via `git worktree add`, but nothing
in the worktree-creation or preflight path runs `mix deps.get` (or any
language-appropriate equivalent). Every `mix`-backed predicate therefore
fails at t0 for an ENVIRONMENTAL reason ("Unchecked dependencies for
environment test ... run mix deps.get"), not a product reason.

This defeats kazi's core guarantee: the vacuous-goal guard (T2.3, concept
R3, `Kazi.Runtime.guard_not_vacuous/4`) observes the goal's full predicate
vector once at t0 specifically so a red predicate at that instant means
"kazi has real work to do" -- proof the predicate measures actual product
behavior, not a rubber stamp. When the failure is really "deps were never
installed," red-at-t0 stops proving anything: the SAME predicate would be
red on a perfectly correct codebase, so its later transition to green
(after a coding agent dispatch) is not evidence of anything either. A
goal's whole acceptance bar is only as trustworthy as its t0 observation.

Issue #1642 (filed 2026-07-21) was independently reproduced again on
2026-09-05 (v1.279.2) by three separate `kazi apply --parallel` lanes, all
hitting the identical dependency error -- see the corroboration comments on
#1642 and the related report on #1751. This is not a hypothetical: it is
the default experience of running a mix-backed (or any build-tool-backed)
goal against a freshly created worktree.

The repo owner decided the fix on the issue (2026-08-08, option 2 of the
options considered there): add a declared setup/provisioning step to the
goal-file schema that the worktree/preflight path runs BEFORE the t0
observation, with a setup failure reported as a distinct environment error,
never surfaced as a predicate red. Two other options were considered and
explicitly rejected on the issue (see Alternatives rejected below):
auto-detecting the build tool, and having the harness provision the
workspace implicitly.

kazi already draws exactly this environment-error-vs-predicate-verdict line
for a structurally identical hazard: issue #1683/T69.2 bounds the t0
observation itself with a startup deadline, and a wedged observation is
reported as `{:error, {:startup_deadline_exceeded, ms}}` -- a named,
structured INFRASTRUCTURE error, never a predicate `:fail`. `[setup]` is
the sibling case: a MISSING precondition to the same observation, reported
the same way.

## Decision

Add an optional `[setup]` table to the goal-file schema:

```toml
[setup]
commands = ["mix deps.get", "mix compile"]
timeout_ms = 300000   # optional; per-command hard deadline, default 300_000
```

* `commands` -- a list of shell command strings, run IN ORDER, each through
  `sh -c`, in the goal's workspace. Required when `[setup]` is declared at
  all (a present-but-empty block is ambiguous authoring intent and fails
  loudly at load, unlike an ABSENT block, which resolves to no setup step).
* `timeout_ms` -- the per-command hard deadline. ALWAYS a positive integer
  (default `300_000`ms) -- there is deliberately no way to author an
  unbounded `[setup]` command, closing the exact class of environmental
  startup wedge #1683/T69.2 already fixed for the observation itself.

The controller (`Kazi.Runtime`) runs the declared commands ONCE, in the
workspace, immediately BEFORE the t0 predicate observation -- in both
`run/2` (the real `kazi apply` path) and `check/2` (the observe-only
merge-gate/`kazi apply --check` surface, ADR-0026 L1), since both perform
the identical t0 observation and a freshly created worktree can reach
either path unprovisioned. An absent `[setup]` block is byte-identical to
before this feature existed (`Kazi.Setup.run/3` no-ops on `nil`).

A setup command that exits non-zero, cannot be started (missing binary, bad
workspace), or overruns `timeout_ms` STOPS at that command (later commands
never run) and returns `{:error, {:setup_failed, failure}}`, where
`failure` names the offending `command`, its `index`, the `reason`
(`:exit_code | :raised | :timeout`), and a bounded `detail` string. This
fails the run/check BEFORE the vacuous-goal guard or the t0 observation
runs at all -- no run record is registered (mirroring how
`guard_not_vacuous` failing today registers nothing), and no harness is
ever dispatched. The CLI renders it as a distinct `status: "error"` result
naming the setup command and the environment-vs-predicate distinction
explicitly, never a predicate verdict.

## Alternatives rejected

Both were raised and rejected on issue #1642 itself before this ADR was
written; they are restated here because they are the two designs most
naturally reached for when "predicates fail because deps aren't installed"
first comes up.

* **Auto-detect the build tool** (see a `mix.exs` -> run `mix deps.get`; see
  a `package.json` -> run `npm install`; ...). Rejected: a detector is one
  more thing to keep in sync with every ecosystem's conventions and their
  drift (workspaces, lockfile-only installs, vendored deps, monorepo
  sub-projects with their own manifests) -- exactly the kind of
  policy-in-core kazi has repeatedly kept out (ADR-0035/ADR-0056's
  no-policy-in-core line: kazi enforces what is DECLARED, it does not infer
  intent). A wrong guess silently either wastes time running an
  unnecessary install or, worse, skips a needed one and reproduces #1642
  under a different disguise.
* **The harness provisions implicitly** (the dispatched coding agent runs
  `mix deps.get` itself as its first move, before touching the failing
  predicate). Rejected: unfalsifiable and non-uniform. It depends on the
  harness/model noticing the missing deps and choosing to fix them before
  attempting the real task -- behavior kazi cannot declare, test, or rely
  on, and it varies per harness and per model. It also still leaves the t0
  OBSERVATION itself (which never dispatches a harness -- see
  `guard_not_vacuous` and `check/2`) exposed to the exact bug, since that
  observation runs before any harness turn ever starts.

A third option -- doing nothing and treating "run deps.get yourself before
calling `kazi apply`" as an operator responsibility -- is the status quo
#1642 reports as broken: it is exactly what the three 2026-09-05
`--parallel` lanes did not do (a worktree is created and handed straight to
`kazi apply`), and prose-only conventions are not enforced.

## Consequences

**Positive:**

* Restores the red-at-t0 guarantee for every build-tool-backed goal: a red
  predicate at t0 means the PRODUCT is wrong, never that the environment
  was never set up.
* Extends the existing environment-error-vs-predicate-verdict pattern
  (`:startup_deadline_exceeded`, issue #1683/T69.2) rather than inventing a
  new error taxonomy.
* Goal-file DATA, not kazi-core policy -- consistent with
  ADR-0035/ADR-0056's no-policy-in-core line and with every other optional
  goal-file block (`[enforcement]`, `[seal]`, `[[capture]]`,
  `[integration]`): absent block, zero behavior change.
* `timeout_ms` is always bounded, so a hung `[setup]` command cannot
  reintroduce the exact startup-wedge class #1683/T69.2 already closed for
  the observation it now precedes.
* `check/2` gets the same fix as `run/2` for free (same insertion point),
  so a merge-gate check against a freshly created worktree is not a false
  red either.

**Negative / accepted trade-offs:**

* One more optional goal-file block to author; a build-tool-backed goal
  that omits `[setup]` is unchanged from today (still red-at-t0 for the
  wrong reason) -- this ADR provides the mechanism, it does not retrofit
  every existing goal-file. `docs/AUTHORING.md` documents when a goal needs
  one.
* `commands` runs through `sh -c`, so a setup step is exactly as portable
  (and exactly as capable) as any other `custom_script`-style shell
  command in the goal-file -- no cross-platform command abstraction is
  attempted, matching every other command-runner surface in the schema
  (ADR-0040).
* A goal author must still know their own project's provisioning command;
  this ADR explicitly does not guess it (see Alternatives rejected).

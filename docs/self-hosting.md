# Self-hosting: kazi builds kazi

This document records the **self-hosting cutover** (plan task T2.6) — the point
from which kazi stops being built *with* hand-driven `/apply` skills and starts
being built *with kazi itself*. From here on, an E3 backlog item is not a task an
agent picks up directly; it is a **kazi goal-file** — a set of acceptance
predicates that fail at t0 because the feature is absent, and that kazi drives a
coding agent in a loop to make objectively true.

It is the milestone the concept names directly: *"Dogfood on real repos through
MVP-2 before any world-facing claim; from creation mode onward, kazi builds
kazi"* (`docs/concept.md` §10, MVP-2 → MVP-3).

## The cutover

| Slices | How kazi was built | Why |
|--------|--------------------|-----|
| 0–2 (E0–E2) | bootstrapped with the existing Claude Code `/apply` skills (waves of agents working `docs/plan.md`) | kazi did not yet exist / could not yet create features |
| 3+ (E3) | authored as **self-hosted kazi goals** — failing acceptance predicates kazi converges | kazi can now reconcile *and* create (Slice 2, T2.1–T2.5), so it can build itself |

The bootstrap is over: Slice 2 (creation mode + the browser provider + the
vacuous-goal guard, T2.1–T2.5) gave kazi the ability to **create** behavior, not
only repair it (concept §10, MVP-2). The Slice-2 creation dogfood (T2.5,
`test/kazi/slice2_dogfood_test.exs`) proved kazi can build a small real feature
from failing acceptance predicates, red → green → live. T2.6 is the cutover that
turns that capability inward: kazi's own E3 backlog becomes its work-list.

The E3 backlog itself lives in `docs/plan.md` (the "E3 — Slice 3+ Backlog"
section: T3.1–T3.7). It is intentionally **coarse**: each item is re-planned as a
self-hosted kazi goal when it is reached, not specified up front.

## How a self-hosted goal works

A kazi goal is *declarative*: it names a goal, a budget, a scope, and the
predicates whose conjunction defines "done" (ADR-0002, goals-as-predicates;
`Kazi.Goal.Loader` for the full goal-file schema). A **self-hosted** goal is
exactly the same machinery with one difference: **the target workspace is the
kazi repo itself**, and the acceptance predicates run kazi's OWN test suite.

The authoring rule (creation mode, ADR-0002, T2.1) is the heart of it:

> Author each acceptance predicate so that it **FAILS at t0 because the feature
> is absent**, and **PASSES once kazi builds it**. The failing predicate *is* the
> work-list — kazi drives a coding agent in a loop until every acceptance
> predicate is objectively `:pass` (or it is stuck / over budget).

For a self-hosted goal the cleanest acceptance predicate is the `test_runner`
provider (`Kazi.Providers.TestRunner`) running kazi's own `mix test` against a
**new, not-yet-existing** test that asserts the desired behavior:

- **At t0** the test (file / case) does not exist, so `mix test <path>` exits
  non-zero → the predicate is `:fail`. There is real work to do, so the
  **vacuous-goal guard** (T2.3) does not trip.
- **Once kazi builds the feature** and lands its acceptance test, the same `mix
  test <path>` exits `0` → the predicate flips to `:pass` and the goal converges.

A `test_runner` predicate's truth is the **exit status of a real command run in
the workspace where the agent edits** — never an agent's opinion (concept §3,
ADR-0002, `Kazi.Providers.TestRunner`). Pair the acceptance predicate with a
**guard** predicate (`guard = true`) that runs the *whole* suite, so the new
feature cannot regress existing behavior — a guard is an invariant that must not
break, not a goal to reach (`Kazi.Predicate`).

### The first self-hosted goal

`priv/goals/e3-t3.4-standing-reconciler.toml` is the first self-hosted goal,
authored as part of this cutover. It specifies **E3 item T3.4 — standing /
continuous reconciler mode (UC-016)**: a maintenance goal that does not terminate
on convergence but keeps its predicates true forever (concept §10, "standing
reconcilers"). Its acceptance criterion is `mix test
test/kazi/standing_reconciler_test.exs`, a test file that **does not exist yet**
— so the predicate fails at t0 and would pass once kazi builds standing mode and
lands that test. A guard runs the full `mix test` suite so nothing regresses.

`test/kazi/goals/e3_t34_standing_reconciler_test.exs` asserts the goal-file loads
into the expected create-mode goal and is non-vacuous at t0 (the acceptance test
file is genuinely absent). It does **not** run the real `claude` harness.

## How to run a self-hosted goal

Point kazi at the goal-file, with the kazi repo as the workspace:

```sh
kazi apply priv/goals/e3-t3.4-standing-reconciler.toml --workspace /path/to/kazi
# or, from a source checkout:
mix kazi.apply priv/goals/e3-t3.4-standing-reconciler.toml --workspace /path/to/kazi
```

`--workspace` is the directory the harness edits and the providers run their
commands in (`Kazi.Providers.TestRunner` runs `mix test` with `cd:` set to the
workspace). For a self-hosted goal that directory **is the kazi repo**.

> Run a self-hosted goal against a **fresh checkout / worktree of kazi**, not the
> tree you are working in — kazi will edit files and open a PR, and you do not
> want it racing your own edits.

## How the reconcile actions apply when the workspace IS kazi

The walking-skeleton actions (ADR-0007) behave the same whether the target is a
fixture or kazi — only the target changes:

- **Harness** (`claude -p`, ADR-0008/0009 — `Kazi.Harness.ClaudeAdapter`). Each
  iteration invokes the coding agent **headless and stateless** (ADR-0008): kazi
  owns the context across iterations, not the harness. The prompt is a **thin,
  deterministic projection of the predicate evidence** (ADR-0009) — the failing
  `mix test` output is handed to the agent as the work to do. When the workspace
  is kazi, the agent is editing kazi's own `lib/` and `test/`.
- **Integrate** (T0.10a, UC-020 — `Kazi.Actions.Integrate`). Once the acceptance
  predicate is green, kazi branches → commits → pushes → **opens a PR** and
  rebase-merges it. When the workspace is kazi, that PR is a PR against the kazi
  repo. **House rule: rebase-and-merge — never squash, never a merge commit.**
- **Deploy** (T0.10b, UC-015 — `Kazi.Actions.Deploy`). Ships the released
  artifact so a *live* probe can verify the goal against running infrastructure.
  For a pure code/test self-hosted goal like T3.4 there may be no live surface to
  deploy (the acceptance predicate is a `test_runner`, not an `http_probe`); the
  deploy arm is a no-op for that goal. A self-hosted goal that *does* change a
  live surface would deploy exactly as a fixture goal does.

## Safety and review expectations

Self-hosting does **not** mean kazi merges into itself unattended. The integrate
action opens a **PR**; a **human reviews and merges it** (rebase-and-merge per the
house rule, `Kazi.Actions.Integrate` and the project `CLAUDE.md` definition of
done). kazi converges the goal and proposes the change; the human is the gate.

- Run self-hosted goals in an **isolated worktree / checkout** of kazi.
- Set a **budget** in the goal-file (`[budget]`) so a stuck loop cannot burn
  unbounded iterations or tokens (`Kazi.Budget`, T1.2).
- The acceptance predicate must be **objective** (a real `mix test` exit code),
  never a judgement call — that is the whole point of goals-as-predicates
  (ADR-0002).
- A converged self-hosted goal still owes the full **definition of done** (tests
  green, formatted, PR rebase-merged with CI green, deployed/verified-live where
  there is a production surface) — see `CLAUDE.md`.

## Authoring pitfalls when `kazi plan` targets kazi itself (T45.10, #1668/#1669)

The T45.10 exit-proof dogfood (2026-07-21) ran the *authoring* surface — not a
hand-written goal-file — against kazi's own repo for the first time, and hit two
gaps that only exist BECAUSE the workspace under test is also the source of the
engine grading it. Both are now handled by `Kazi.Authoring.SelfHost`, which is a
no-op the instant `workspace` is not kazi's own tree (no `lib/kazi/providers`
there) — an ordinary target repo is unaffected.

**A `cli`/`custom_script` predicate can measure the LAST BUILD, not the source
edit (#1668).** Asked to fix kazi's own CLI, a drafted `cli` predicate shelled
out to `kazi help` — the INSTALLED binary. A source edit cannot change an
already-built binary, so the predicate was unsatisfiable from the moment it was
written:

```
kazi help | grep -c "kazi dashboard"        -> 0   (installed binary)
mix run -e 'Kazi.CLI.run(["help"])' | ...   -> 1   (modified source, same tree)
```

`kazi plan`'s drafting prompt now carries an explicit rule against this
(`Kazi.Authoring.build_prompt/2`'s "SELF-HOSTING TRAP" paragraph), and any
`cli`/`custom_script` predicate whose `cmd` still names the workspace's own
built executable (`Kazi.Authoring.SelfHost.own_binary_name/1`, read from
`mix.exs`'s `escript` config) surfaces a `self-hosting-cli-predicate` entry in
the draft's clarify floor (`kazi plan --json`'s `clarify` array, and a `warning:`
line in the human report) — ADVISORY, never a drafting blocker. Prefer a
hermetic in-process check (`mix test`, `mix run -e '...'`) instead, or add a
build/install step before the predicate runs.

**No `[enforcement]` block means the agent can edit its own grader (#1669).**
`kazi plan` used to author no `[enforcement]` table at all, so a dispatched
agent was free to edit the very provider file that grades one of its own
predicates — and, in the dogfood, did (a legitimate fix, but nothing
distinguished it from one that was not; see #1663). `kazi plan` now defaults
`read_only_paths` (ADR-0042) to the provider file(s) implementing the drafted
goal's OWN predicate kinds — never the whole engine, so kazi's routine
self-improvement of an unrelated provider is not additionally flagged
(`Kazi.Authoring.SelfHost.default_read_only_paths/2`). This only fills a true
absence: a goal that already carries an authored `[enforcement]` block (of any
shape) is left alone.

## See also

- `docs/concept.md` — canonical concept (§3 objective predicates, §10 slices).
- `docs/plan.md` — the live plan; the **E3 — Slice 3+ Backlog** (T3.1–T3.7) is
  the list of items to author as self-hosted goals.
- `docs/adr/0001` — positioning: outer-loop reconciler.
- `docs/adr/0002` — goals-as-predicates (the authoring model).
- `docs/adr/0007` — build strategy: walking skeleton, deepen later.
- `docs/adr/0008` — harness invocation: headless, stateless per iteration.
- `docs/adr/0009` — prompt construction: thin, deterministic evidence projection.
- `Kazi.Goal.Loader` — the goal-file TOML schema.
- `priv/examples/create_feature.toml` — the creation-mode authoring pattern.
- `priv/goals/e3-t3.4-standing-reconciler.toml` — the first self-hosted goal.
- `docs/adr/0042-anti-gaming-enforcement.md` — `[enforcement]`/`read_only_paths`.
- `Kazi.Authoring.SelfHost` — the self-hosting detection behind #1668/#1669.
- `priv/examples/doc_lifecycle.goal.toml` — the reference `[enforcement]` shape.

# Anti-gaming enforcement (the `[enforcement]` profile)

kazi exists because an agent stops when it *believes* it is done, so the loop may
only terminate `:converged` when objective predicates pass with evidence
(concept §2, Gap 1: "truth lives in the controller, not the agent"). But a visible
check is gameable by construction — METR (2025-06-05) found reward hacking **>43x
more common** when the model could see the entire scoring function. The
`enforcement` profile (T32.4, ADR-0042) turns kazi's guard markers from convention
into a guarantee a capable agent cannot quietly defeat.

It is **default-on for goals kazi authors in creation mode** (the agent writes the
tests/features it is then graded on — the highest gaming-risk surface) and
**opt-in for repair goals**. Declaring an `[enforcement]` table opts in regardless
of mode; set `enabled = false` to opt a creation goal out.

## The five guarantees

| # | Guarantee | What it closes |
|---|-----------|----------------|
| 1 | **clean-tree + separate-process checker isolation** | the agent editing the grader / "operator-overloading" — METR's documented in-process-grader-edit class |
| 2 | **read-only lease of predicate + test paths** | the agent silently rewriting the checks it is graded on (a write is *flagged*, not silent) |
| 3 | **skipped / errored / xfail → `:fail`** | `pytest.skip` / `exit(0)` / catch-and-swallow making a suite green by not running |
| 4 | **test-count + coverage ratchets as guards** | deleting/weakening a test to make the suite pass (a guard regression, not progress) |
| 7 | **the guarantees are reported, not silent** | a "done" you can't audit — `kazi apply --json` shows the bar that was held |

(Guarantee 5, the advisory diff-inspection guard, is T32.5; guarantee 6, the
held-out acceptance subset, is the `held_out` predicate flag, T32.6.)

### 1. Clean-tree + separate-process isolation

The **GUARD** and **held-out** predicates — the tamper-prone graders — are resolved
and run from a **clean detached git worktree** at `clean_ref` (default `HEAD`), in a
**separate OS process** (kazi's command-runner providers already shell out via a
fresh subprocess). So an in-iteration edit to a checker file in the agent's working
copy **cannot change the verdict**: the worktree is the committed state, not the
working copy.

The ordinary *visible* predicates the agent iterates on still run against the
working copy, so the agent's in-flight work is seen and the loop converges normally.

> **The verified seam.** The only place `Kazi.Loop` invokes a provider is
> `run_provider/3`, with a context carrying `workspace: data.workspace`. Enforcement
> swaps that workspace for the clean worktree for the duration of an observation
> (`Kazi.Loop.observe_with_isolation/1` → `Kazi.Enforcement.Isolation.with_clean_tree/3`,
> the same `git worktree add --detach` pattern `Kazi.Ratchet` uses) and removes it
> after. Full container isolation is **deferred** (ADR-0042 §1). See the verified
> seam note in `docs/adr/0042-anti-gaming-enforcement.md`.

**Honest reporting.** When the workspace is not a git repo (or `clean_ref` cannot be
checked out) isolation **degrades gracefully** — the checker still runs, against the
working copy — and `clean_tree` **drops out of the reported guarantees**. A partial
guarantee is visible, never assumed.

### 2. Read-only lease

`read_only_paths` are content-hashed *before* the fixer agent is dispatched and
re-hashed *after*; any path that changed is a flagged `read_only_write` gaming event
(surfaced in `--json`), never a silent edit.

### 3. Skipped / errored / xfail → `:fail`

A checker that "passed" only by skipping work is not passing. A `:pass` whose
evidence shows a skipped/errored/xfail sub-result (a structured count, or JUnit
`<skipped>`/`<error>`, or an `xfail` marker in the output) is downgraded to `:fail`.

### 4. Test-count + coverage ratchets as guards

Each `[[enforcement.guard]]` becomes a `:ratchet` GUARD predicate (the T32.3
machinery, see [the ratchet how-to](../ratchet-predicate.md)) with
`allowed_regression = 0` ("may only improve") by default. Deleting a test makes the
count metric drop — a guard regression that fails the vector, not progress.

## Goal-file shape

```toml
id = "ship-widgets"
mode = "create"            # creation mode → enforcement default-on anyway

[enforcement]
enabled = true             # default true when the table is present
clean_tree = true          # run guards/held-out graders from a clean worktree
clean_ref = "HEAD"         # the clean ref (default HEAD)
fail_on_skip = true        # skipped/errored/xfail → :fail
read_only_paths = ["test/acceptance", "predicates.toml"]

# A test-count ratchet guard: the suite may only grow.
[[enforcement.guard]]
id = "test-count-no-drop"
direction = "higher_better"
baseline = "stored"
allowed_regression = 0
metric = { cmd = "sh", args = ["-c", "grep -rc 'test ' test | paste -sd+ - | bc"] }

# A coverage ratchet guard.
[[enforcement.guard]]
id = "coverage-no-drop"
direction = "higher_better"
baseline = "stored"
metric = { cmd = "scripts/coverage", args = ["--json"], path = "$.totals.percent" }
```

See `priv/examples/enforcement.goal.toml` for a runnable starting point.

## What `--json` reports

`kazi apply --json` carries an `enforcement` object (see `kazi schema apply`):

```json
{
  "enforcement": {
    "active": true,
    "guarantees": ["clean_tree", "fail_on_skip", "ratchet_guards", "read_only_lease", "separate_process"],
    "gaming_events": [{ "type": "read_only_write", "path": "predicates.toml", "iteration": 2 }]
  }
}
```

`guarantees` is the **actual** active set — `clean_tree` is absent when isolation
degraded — so an orchestrator (and a human) can see exactly which part of the bar
was held.

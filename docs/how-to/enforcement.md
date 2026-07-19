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
| 5 | **diff-inspection gaming guard (ADVISORY)** | skip/xfail markers, test-input special-casing, grader edits — *surfaced + progress-downgraded*, not hard-blocked |
| 7 | **the guarantees are reported, not silent** | a "done" you can't audit — `kazi apply --json` shows the bar that was held |

(Guarantee 5, the advisory diff-inspection guard, lands in T32.5 — see [the
diff-inspection guard](#5-diff-inspection-gaming-guard-advisory) below; guarantee 6,
the held-out acceptance subset, is the `held_out` predicate flag, T32.6.)

### 1. Clean-tree + separate-process isolation

The **GUARD** and **held-out** predicates — the tamper-prone graders — are resolved
and run from a **clean detached git worktree** at `clean_ref` (default `HEAD`), in a
**separate OS process** (kazi's command-runner providers already shell out via a
fresh subprocess). Before the checker runs, the worktree is **overlaid** with the
agent's candidate working-tree state (tracked edits + untracked new files), then the
declared `read_only_paths` — the grader's OWN definition files — are **re-pinned**
to `clean_ref`. So an in-iteration edit to a *grader* file in the agent's working
copy still **cannot change the verdict** (that path is always resolved from the
committed state), while an in-iteration edit to the *candidate fix under test* IS
seen — a held-out predicate can converge as soon as the working copy satisfies it,
without waiting for `integrate` to commit it first (deep-review 001 H1).

The ordinary *visible* predicates the agent iterates on still run against the
working copy, so the agent's in-flight work is seen and the loop converges normally.

> **Only `read_only_paths` is pinned.** A grader/checker/test file is protected from
> clean-tree overlay if and only if it is listed in `read_only_paths`. A file NOT
> listed there is overlaid like any other candidate file — so a `[[enforcement]]`
> block that declares a held-out `:custom_script` checker should list that checker's
> own script/config path in `read_only_paths` if it must stay tamper-proof.

> **The verified seam.** The only place `Kazi.Loop` invokes a provider is
> `run_provider/3`, with a context carrying `workspace: data.workspace`. Enforcement
> swaps that workspace for the clean worktree for the duration of an observation
> (`Kazi.Loop.observe_with_isolation/1` → `Kazi.Enforcement.Isolation.with_clean_tree/4`,
> the same `git worktree add --detach` pattern `Kazi.Ratchet` uses) and removes it
> after. Full container isolation is **deferred** (ADR-0042 §1). See the verified
> seam note + the H1 fix section in `docs/adr/0042-anti-gaming-enforcement.md`.

**Honest reporting.** When the workspace is not a git repo (or `clean_ref` cannot be
checked out, or the overlay/pin steps fail) isolation **degrades gracefully** — the
checker still runs, against the working copy — and `clean_tree` **drops out of the
reported guarantees**. A partial guarantee is visible, never assumed.

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

### 5. Diff-inspection gaming guard (ADVISORY)

Before crediting an iteration as *progress*, kazi runs a cheap structural scan of
the agent's diff (`git diff HEAD`, the iteration's uncommitted changes) for gaming
SIGNATURES. This is the **advisory** companion to the hard guards above — it
**surfaces** a flagged event and **downgrades** the iteration's progress; it never
hard-blocks convergence or crashes the loop. The ratchets (§4) and the read-only
lease (§2) remain the hard guarantees; the diff guard is the cheap early warning,
deliberately tuned for a **low false-positive rate** ("start advisory — surface,
don't block", ADR-0042 "Consequences").

It is implemented as `Kazi.Enforcement.DiffGuard` (pure) wired into the loop's
post-dispatch path (`Kazi.Loop.flag_diff_gaming/1`). Three signatures fire:

| Signature | What it catches |
|-----------|-----------------|
| `skip_marker` | a newly-added skip/xfail/ignore/disabled marker — pytest `@pytest.mark.skip`/`xfail`, `pytest.skip(`, `unittest.skip`, `raise SkipTest`; JS/TS `it.skip(`/`describe.skip(`/`xit(`; Go `t.Skip(`; Rust `#[ignore]`; JUnit `@Disabled`/`@Ignore`; ExUnit `@tag :skip` |
| `test_special_casing` | an added `if <input-ish> == <literal>` branch — hardcoding behaviour for a known test input (`if input == <test_case>`) |
| `grader_edit` | an add/delete touching a grader/predicate path (the goal's `read_only_paths`, plus a conservative name heuristic for `predicates.*` / `*.goal.toml` / a `graders`/`predicates` path segment) |

Only ADDED lines carry the `skip_marker` / `test_special_casing` signatures (a pure
deletion or a context line is not a signal); `grader_edit` also fires on a deletion,
since deleting a check is itself the exploit. An ordinary `if mode == "create"`
branch or a whitespace/rename refactor is **not** flagged.

**What "downgrade progress" means.** A flagged iteration's graded SCORE is discounted
in the stuck classifier (`Kazi.Loop.StuckDetector`), so a GAMED apparent score
improvement (ADR-0041's graded gradient) no longer rescues the loop from a stuck
verdict. The boolean failing-set logic is untouched and the stored predicate vector
keeps its real score — so a genuine convergence is never blocked; only the *progress
view* the stuck detector reads is downgraded. The flagged events surface in `--json`
(below) as `diff_gaming` entries.

## Sealed predicates — cryptographic tamper detection (the `[seal]` block, ADR-0080)

The read-only lease (§2) is **advisory**: a write to a `read_only_path` is flagged
as a `read_only_write` event, but the run continues and can still report
`converged`. **Sealing** is the layer that makes tampering with the acceptance
contract **fatal**. It is the enforcement layer's teeth.

Declare the files whose CONTENT is part of the acceptance bar in a `[seal]` block:

```toml
[seal]
enabled = true                       # default true; false fully opts out
sealed_inputs = [
  "checks/pixel_manifest.toml",      # threshold manifests
  "checks/reference/**/*.png",       # reference images (globs allowed)
  "checks/selftest_fixtures",        # a directory seals its whole tree
]
mutable_inputs = [                   # subtractive opt-out (see below)
  "checks/reference/regenerated_baseline.png",
]
```

At run start kazi content-hashes (SHA-256) the goal-file plus every sealed input.
Before every observe pass it re-hashes; the FIRST mismatch terminates the run in
a distinct `tampered` status (never `converged`, exit non-zero), with the
offending file named in `tampered_file` (`{ path, change }` in `--json`, a
`TAMPERED` line in the human report). A converging worker that loosens its own
threshold manifest to reach green can no longer get away with it — the run is
void, not green.

**The goal-file itself is always implicitly sealed** whenever sealing is enabled,
even with no `[seal]` block — so every goal already gets "the declared bar cannot
be edited mid-run" for free. This is fully backward-compatible: a goal-file with
no `[seal]` block seals only its own goal-file.

**Opt-outs — two levers for two legitimate cases:**

- **`mutable_inputs`** (subtractive) — a path excluded from the seal even if a
  `sealed_inputs` glob matches it. Use it for an input the goal legitimately
  **regenerates** while converging (e.g. a ratchet that rewrites one golden
  baseline). The rest of the sealed tree stays sealed.
- **`enabled = false`** (whole-run) — disables sealing entirely, INCLUDING the
  implicit goal-file seal. Use it for the rare self-modifying / standing goal that
  rewrites its own contract by design (e.g. the doc-lifecycle standing goal). The
  goal-file cannot be carved out with `mutable_inputs` — "the bar is mutable" is
  always a single, greppable, all-or-nothing declaration.

**Sealing vs the read-only lease.** They are orthogonal and compose; a path may be
in both.

| | `[enforcement] read_only_paths` (§2) | `[seal] sealed_inputs` |
|---|---|---|
| Layer | advisory pathing | cryptographic detection |
| Checked | once per dispatch | every observe pass |
| On violation | flag a `read_only_write` event, run continues | terminate `tampered`, run void |
| Scope | the agent's write lease | acceptance-contract immutability |

See ADR-0080 for the full rationale and manifest format.

## Role-scoped path policy (scenario predicates, ADR-0064)

A `scenario` predicate (see [the scenario how-to](../scenario-predicate.md)) has TWO
dispatch roles that must be **write-disjoint**: the **fixer** patches the app, the
**demonstrator** mints the pin (the grader). ADR-0064 decision 7 grants the one
mechanism extension for this — `read_only_paths` made **role-scoped** — carried on
the profile's optional `roles` map and resolved by `Kazi.Enforcement.for_role/2`:

```toml
[enforcement.roles.fixer]
# The fixer keeps its normal write surface, but pins and specs are read-only to it
# (it cannot forge the grader). Same detection as the §2 lease.
read_only_paths = ["docs/specs/pat.feature", "docs/specs/pins/pat.pin.json"]

[enforcement.roles.demonstrator]
# INVERTED: the demonstrator may write ONLY these paths — everything else is
# read-only. A write outside them is a `disallowed_write` violation (the opposite
# direction from the fixer's read_only_paths). The demonstrator cannot patch the
# app, so a broken capability demonstrates as an honest failure.
allowed_write_paths = ["docs/specs/pins/pat.pin.json"]
```

**Derived by default.** When a goal has ≥ 1 `scenario` predicate and **no**
`[enforcement.roles]` block is authored, kazi derives the policy automatically: the
fixer's `read_only_paths` gains every scenario predicate's `spec` **and** `pin`
path, and the demonstrator's `allowed_write_paths` is **exactly** the pin paths.
An explicit block is the author's override and wins untouched. A goal with **no**
scenario predicate is byte-identical to today — `roles` stays empty and nothing in
the five guarantees above changes.

Both directions run over the SAME digest diff as the §2 lease
(`Kazi.Enforcement.detect_role_writes/5`): the fixer flags a changed
`read_only_paths` entry as `read_only_write`; the demonstrator flags any changed
path NOT under `allowed_write_paths` as `disallowed_write`.

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
    "gaming_events": [
      { "type": "read_only_write", "path": "predicates.toml", "iteration": 2 },
      { "type": "diff_gaming", "signature": "skip_marker", "file": "test/widget_test.py", "line": 12, "snippet": "@pytest.mark.skip", "iteration": 3 }
    ]
  }
}
```

`gaming_events` mixes the hard-guard read-only-write flags (§2) and the advisory
`diff_gaming` flags (§5). A `diff_gaming` entry is advisory — it downgrades that
iteration's progress and is surfaced for a human/orchestrator to audit; it does not
on its own fail the goal.

`guarantees` is the **actual** active set — `clean_tree` is absent when isolation
degraded — so an orchestrator (and a human) can see exactly which part of the bar
was held.

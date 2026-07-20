# ADR-0080: Sealed predicates — cryptographic tamper detection on the acceptance contract

## Status

Accepted

## Date

2026-07-19

## Context

Predicate immutability is currently honor-system. A goal's description says
"never edit the manifest / thresholds", and the worker usually complies. But a
converging worker has both motive and write access: in a consumer project a
worker loosened the visual-check thresholds in its OWN goal's pixel manifest to
reach green. Nothing in kazi detected it — the run reported `converged` and the
tampering was only found at human review, if ever.

This is worst for visual/UI goals, where predicates consume auxiliary files that
live in the workspace (pixel-check manifests, reference images, selftest
fixtures) and the worker can edit them as freely as source code. A reconcile
loop whose acceptance criteria are writable by the reconciler has **no objective
termination guarantee** — the central promise of the controller (ADR-0001).

kazi already has the two mechanical halves of the fix, but neither closes the
gap:

- **ADR-0042 `[enforcement] read_only_paths`** content-hashes leased paths before
  a dispatch and flags a post-dispatch write as a `gaming_event`. It is
  deliberately **advisory**: the run continues and can still report `converged`.
  A flag nobody blocks on does not stop a worker who games the bar to green.
- **goal-drift-guard (#1415)** snapshots the goal-file at t0 and reports
  `goal_drifted` in the result. Also **observational** — it never changes
  `status`.

What is missing is a layer that treats the acceptance contract's bytes as
**immutable for the duration of the run** and makes a mismatch **fatal**, not
advisory.

## Decision

Add **sealed predicates**: at run start, content-hash the goal-file and every
file each predicate declares as an input; re-verify at every observe pass; a
mismatch flips the run to a distinct terminal **`tampered`** hard-FAIL naming the
offending file. Never silent, never green.

### 1. The `[seal]` goal-file block

```toml
[seal]
enabled = true                       # default true; false fully opts out (see §4)
sealed_inputs = [                    # paths whose CONTENT is part of the contract
  "checks/pixel_manifest.toml",
  "checks/reference/**/*.png",       # globs allowed (Path.wildcard semantics)
  "checks/selftest_fixtures",        # a directory seals its whole file tree
]
mutable_inputs = [                   # subtractive opt-out (see §4)
  "checks/reference/regenerated_baseline.png",
]
```

- `sealed_inputs` — repo-relative paths (globs allowed) whose byte content is part
  of the acceptance contract: threshold manifests, reference images, checker
  scripts, fixtures. A directory entry seals its entire sorted file tree, so
  adding/removing/altering a file under it is detected.
- **The goal-file itself is always implicitly sealed** whenever sealing is
  enabled, whether or not a `[seal]` block is present. A goal-file with no
  `[seal]` block therefore already gets a strict improvement (the bar it declares
  cannot be edited mid-run) at zero authoring cost — the change is fully
  backward-compatible.

### 2. Seal manifest format

The manifest computed at run start is a map `label => {absolute_path, digest}`:

- `digest` is `SHA-256` of the file's bytes (reusing the ADR-0042
  `Kazi.Enforcement` hashing primitive), or the `:absent` sentinel when the path
  does not exist at t0.
- `label` is the human-facing path used in the tamper diagnostic: the
  workspace-relative path for a sealed input, and the goal-file's source path for
  the implicit goal-file entry.
- Globs are expanded to concrete files **at t0**, and each matched file is sealed
  individually. A file that appears later (matching a glob but absent at t0) is
  itself a tamper signal (`:added`), because the contract's file set changed.

### 3. Lifecycle: seal at t0, verify every observe

- **At run start** (`Kazi.Runtime.run/2`, alongside the existing goal-drift t0
  snapshot), arm the seal from `goal.seal` + the goal-file source path + the
  workspace, and thread the manifest into the loop.
- **Before every observe pass** (in the loop's `:observing` handler, at the same
  precedence as the ADR-0053 workspace-liveness precheck — a distinct fatal cause
  checked BEFORE budget/observe), re-hash the sealed paths and compare to the
  manifest. The workspace-liveness check runs FIRST, so a vanished workspace
  reports `workspace_missing`, not a spurious `tampered`.
- **On the first mismatch**, terminate the run in a new terminal loop outcome
  `:tampered`. `build_result/2` maps it to `outcome: :tampered` and can NEVER
  collapse it to `:converged`. The result carries a `tampered_file` diagnostic
  `%{path:, change: :modified | :removed | :added}`. `Kazi.Runtime.registry_status/2`
  maps `:tampered` to the `"tampered"` read-model status, and the CLI renders a
  distinct `tampered` status line and exits non-zero.

Verification is cheap (hashing a handful of files per observe) and adds
negligible time to an observe pass.

### 4. Opt-out for goals that legitimately mutate their inputs

Two levers, because there are two legitimate cases:

- **`mutable_inputs`** (subtractive) — a path listed here is excluded from the
  seal even if a `sealed_inputs` glob would otherwise match it. This is the
  precise opt-out for a goal that seals a directory of fixtures but legitimately
  **regenerates one baseline** as part of converging (e.g. a ratchet that rewrites
  a golden file). The rest of the tree stays sealed.
- **`enabled = false`** (whole-run opt-out) — disables sealing entirely,
  INCLUDING the implicit goal-file seal. This is for the rare self-modifying /
  standing goal that rewrites its own contract by design (e.g. the doc-lifecycle
  standing goal, T31.6). Explicit and visible in the goal-file, never a silent
  default.

The goal-file itself cannot be carved out with `mutable_inputs` — a goal that
must rewrite its own goal-file uses `enabled = false`, so "the bar is mutable"
is always a single, greppable, all-or-nothing declaration rather than a subtle
partial exception.

### 5. Interplay with ADR-0042 enforcement

Sealing and `[enforcement] read_only_paths` are **orthogonal layers**, and both
may name the same path:

| | ADR-0042 `read_only_paths` | ADR-0080 seal |
|---|---|---|
| Layer | advisory pathing | cryptographic detection |
| Checked | once per dispatch | every observe pass |
| On violation | append a `gaming_event`, run continues | terminal `tampered` hard-FAIL |
| Scope | agent write lease | acceptance-contract immutability |

`read_only_paths` says "the agent should not write here" and surfaces a write as
evidence; the seal says "if the acceptance contract's bytes change, this run is
void." The seal is strictly stronger and is the enforcement layer's teeth. They
compose: a path in both gets the advisory flag AND the hard stop; the seal wins.
The seal deliberately does NOT route through the `gaming_events` advisory path.

## Consequences

- A run whose worker edits the goal-file or a sealed input mid-run terminates
  `tampered`, exit non-zero, and can never report `converged` — the objective
  termination guarantee is restored for goals that opt in (and, for the goal-file
  itself, for every goal).
- Backward-compatible: a goal-file with no `[seal]` block seals only its own
  goal-file; an in-memory goal (no source path) and a `Loop.start_link` with no
  seal manifest are byte-identical to today.
- The tamper diagnostic names the file and the kind of change, but never embeds
  the file's contents (size + open-source-leak hygiene, ADR-0034).
- Follow-up: a richer diff summary in the diagnostic, and per-predicate
  declaration of inputs (so the seal set can be derived rather than authored) are
  left for later; this ADR ships the author-declared `sealed_inputs` form.

## Amendment (2026-07-20): precedence over goal-drift-guard for the goal-file

**The accepted decision above is unchanged.** This note records the precedence
the implementation settled when the two mechanisms collided, discovered when
this ADR's implicit goal-file seal turned `Kazi.Runtime.GoalDriftTest`'s
"deleted a failing predicate" scenario from `:over_budget` into `:tampered`.

Sealing and **goal-drift-guard** (#1415) answer the same question for the same
file: *the dispatched agent edited the goal-file mid-run — now what?* Before this
ADR, drift's answer was observational (`goal_drifted`/`goal_drift` on the result,
`status` untouched, run continues to its natural terminal). This ADR's answer is
fatal (`:tampered`, run void). Both refuse to report `converged`.

**Precedence: the seal wins the OUTCOME; goal-drift remains the DIAGNOSTIC.**

- A tampered goal-file terminates the run `:tampered` with `tampered_file`
  (path + change kind), not the natural budget/stuck terminal. Rationale: (1)
  this ADR's Context names goal-drift-guard as insufficient *precisely* because
  it "never changes status", so drift-wins would silently overturn the accepted
  decision; (2) honest cause attribution (ADR-0046) — `:over_budget` misreports a
  tampered contract as "the work was too hard"; (3) fail-fast — a void run should
  not keep spending budget; (4) one answer for "acceptance-contract bytes
  changed", whether the file is the goal-file or a declared sealed input.
- **What survives.** `goal_drifted`/`goal_drift` are still computed and still
  attached to the `:tampered` result (`Kazi.Runtime.put_goal_drift/3` is
  outcome-agnostic), so the operator keeps drift's unique value — *which*
  predicate ids were added/removed/changed. The seal alone names only the file.
  Drift is demoted from an outcome mechanism to the explanation of one.
- **What this COSTS (stated plainly; an earlier draft of this note claimed
  "nothing is lost", which was too generous to the winning side).** Two real
  regressions follow from sealing the goal-file *implicitly*:
  1. **`goal_drifted` becomes effectively unreachable in production for the
     goal-file.** Because every goal-file is sealed by default, the seal
     preempts drift on essentially every run that would have reported it. The
     field survives on the `:tampered` result, but the *observational* path it
     was built for — a run that reaches its natural terminal and reports the
     delta — is now reachable only by explicitly setting `[seal] enabled = false`.
  2. **Good-faith goal-file edits are now fatal.** A regenerated or templated
     goal-file, or an operator correcting a typo mid-run, terminates the run
     `:tampered` rather than producing the more informative drift report. The
     escape hatches are `[seal] mutable_inputs` and `[seal] enabled = false`,
     but the default is now strict where it used to be tolerant.

### Considered and rejected: opt-in sealing

The alternative — **sealing is opt-in per goal-file: no `[seal]` block seals
nothing, declaring `[seal]` opts the goal-file in alongside the declared
inputs** — was implemented and briefly merged before being reverted in favour of
the precedence above. It is recorded here so it is not re-litigated from scratch.

Its merits are real and are the source of the two costs listed above:

- It preserves the shipped #1415 contract for goals that say nothing about
  sealing — the original t0 bar still governs, and drift stays observational.
- It keeps `goal_drifted` reachable in production, instead of making the field
  nearly vestigial for the goal-file.
- It still covers the #1520 incident class in full, because the goal in that
  incident declares `sealed_inputs` and therefore opts in.
- It is strictly backward-compatible for every pre-ADR-0080 goal-file.

**Why it lost:** opt-in makes this ADR's central claim — *the bar that grades
the work cannot be edited mid-run* — **false by default**. A worker's goal-file
would be immutable only when its author had already thought to ask for that,
which is precisely the honour-system posture the Context section identifies as
the thing to fix. The same objection defeats "drift wins outright": both leave
the default state of a kazi run one where the acceptance contract is editable by
the party being graded. Between a default that is too strict (recoverable via
two documented opt-outs, and loudly diagnosed when it fires) and a default that
is too permissive (silent, and invisible until an audit), this ADR takes the
strict default and pays the costs above.

If the reachability cost in (1) proves to matter more in practice than the
tamper protection it buys, the honest fix is a superseding ADR that revisits the
default — not a quiet flip of the implementation.
- **"The ORIGINAL bar wins" is untouched.** That guarantee is structural to the
  loop (the goal-file is parsed once at t0 and never re-read), not something
  either mechanism confers — so a tampered run still cannot fake convergence.
- **Drift is subordinate, not retired.** With `[seal] enabled = false` the
  goal-file is unsealed and drift reverts to its original observational contract:
  the run reaches its natural terminal and still reports the delta. Both branches
  are pinned in `test/kazi/runtime/goal_drift_test.exs`.
- **Consequence of ordering:** the seal verifies *before* each observe, so a
  tampered run's terminal vector is the last PRE-tamper observation. Work the
  agent did in the tampering dispatch is deliberately not graded — once the
  contract is void there is nothing trustworthy to grade against.

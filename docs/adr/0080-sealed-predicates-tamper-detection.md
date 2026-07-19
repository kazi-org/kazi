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

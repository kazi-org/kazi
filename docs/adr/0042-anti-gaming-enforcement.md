# ADR 0042: Anti-gaming enforcement — make "truth lives in the controller" real, not declarative

## Status
Accepted

## Date
2026-06-24

## Refines
ADR-0002 (the goal contract: guard predicates "block gaming"; acceptance predicates
fail at t0). Those are DECLARATIVE markers today. This ADR adds the ENFORCEMENT that
makes them resistant to a capable agent, which is the whole premise of kazi (concept
§2, Gap 1: "truth lives in the controller, not the agent").

## Context

kazi exists because an agent stops when it BELIEVES it is done, so the loop may only
terminate `:converged` when objective predicates pass with evidence. But the research
note (`docs/research/predicate-verification-landscape.md`) shows that visible
predicates are gameable by construction, and that kazi's current defenses are
convention, not enforcement:

- METR (2025-06-05): reward hacking was **>43x more common** when the model could
  **see the entire scoring function**. This is the empirical mandate for keeping the
  checker out of the agent's reach.
- EvalPlus: extending HumanEval tests 80x revealed ~20-29% of "passing" solutions were
  wrong — overfitting to visible tests (Goodhart's law).
- Anthropic *Sycophancy to Subterfuge* (arXiv:2406.10162): a model trained on petty
  sycophancy zero-shot generalised to **rewriting its own reward to return a perfect
  score and hiding it**. Small letter-vs-intent gaps generalise to grader-tampering.

The documented coding-agent exploits — delete/weaken failing tests, `pytest.skip` /
`exit(0)`, hardcode the expected output, edit the grader, `git log` the fix, read a
hidden answer file — each have a known counter (read-only/hidden tests, run the
checker outside the sandbox, treat skips as failures, test-count + coverage ratchets,
diff inspection, strip solution history, held-out acceptance set).

## Decision

Add an `enforcement` profile for a goal that is **default-on for goals kazi authors in
creation mode** (the highest gaming-risk surface — the agent writes tests/features) and
**opt-in for repair goals** (operator decision, 2026-06-24), with these guarantees:

1. **The checker runs at the CLEAN-TREE + SEPARATE-PROCESS isolation level** (operator
   decision, 2026-06-24). Two parts: (a) evidence-bearing checker definitions and their
   inputs are resolved from a CLEAN tree, not the agent's working copy — stopping
   file-tampering; (b) the checker runs in a SEPARATE OS process the agent cannot
   introspect or monkey-patch — stopping the operator-overloading / stack-introspection
   / in-process-grader-edit class METR documented ("don't trust files, outputs, or
   state from inside the sandbox"). Full container/sandbox isolation (the strongest
   rung) is DEFERRED — it needs new infra and the clean-tree + separate-process level
   closes the documented exploits at far lower cost; revisit if a container-escape-class
   exploit is observed.

2. **Predicate + test files are leased READ-ONLY to fixer agents.** The blast-radius
   lease (ADR-0006) gains a read-only class; the goal's predicate definitions and the
   test paths they execute are leased read-only to dispatched fixers ("reduces hacking
   rate to near zero"). A write attempt to a read-only path is a flagged event, not a
   silent edit.

3. **Skipped / errored / xfail sub-results map to `:fail`, never `:pass`.** The
   `test_runner` and `custom_script` providers parse JUnit/structured output and count
   `skipped`/`error`/`xfail` as not-passing. This closes the `raise SkipTest` /
   `exit(0)` / catch-and-swallow class.

4. **Test-count and coverage RATCHETS are first-class guards.** Using the ADR-0041
   ratchet mode: test count may only increase; coverage may only increase (within
   `allowed_regression`). Deleting/weakening a test to make the suite green is a guard
   regression, not progress. This is the concrete form of ADR-0002's "test-count must
   not drop."

5. **Diff inspection guard.** Before counting an iteration as progress, kazi may run a
   cheap structural check on the agent's diff for gaming signatures — edits to the
   predicate/grader files, `if input == <test_case>` special-casing, new
   `skip`/`xfail` markers. A hit downgrades the iteration and surfaces evidence rather
   than crediting a false pass. (Heuristic + advisory at first; ratchets in §4 are the
   hard guard.)

6. **Held-out acceptance subset (optional).** A goal may mark an acceptance subset
   `held_out = true`: those predicates are evaluated by the controller but their
   definitions/inputs are NOT placed in the agent's context — the visible-for-iteration
   vs hidden-for-acceptance split (Codeforces pretests vs system tests; SWE-bench
   withholds gold tests). Convergence requires the held-out set to pass too.

7. **The guarantees are reported, not silent.** `kazi status`/`--json` surfaces which
   enforcement guarantees are active for a goal, and any flagged gaming event, so the
   orchestrator (and a human) can see that the bar was held — honesty per the global
   definition of done.

## Consequences

- kazi's core claim ("objective termination the cheap implementer cannot fake",
  concept §4) becomes enforced for the two-tier economics case (ADR-0023/0033): a
  cheap grind model cannot declare victory by gaming a visible check.
- Read-only leases compose with the native scheduler (ADR-0027) and the existing
  lease substrate; this is an extension of leasing, not a new mechanism.
- Risk: false positives in the diff-inspection guard (a legitimate refactor touches a
  test). Mitigated by starting advisory (surface, don't block) and relying on the
  ratchets (§4) for the hard guarantees; the read-only lease is a flag + evidence, not
  a hard failure of the agent.
- Risk: held-out predicates reduce the gradient the agent sees (it can't climb what it
  can't see). Acceptable and intentional — held-out is opt-in for the acceptance
  subset; the visible predicates still provide the climbable signal (ADR-0041).
- Risk: "run the checker outside the sandbox" interacts with how dispatch + worktrees
  are wired; the exact seam needs verification against `loop.ex` before implementation
  (flagged as a task precondition, not assumed).

## Verified seam (T32.4, the precondition discharged)

The precondition flagged in "Consequences" — verify "run the checker outside the
agent's reach" against `loop.ex` before implementation — was discharged when T32.4
landed. The findings:

- **Where a provider is invoked.** `Kazi.Loop` invokes a checker in exactly ONE
  place: `run_provider/3` (`lib/kazi/loop.ex`), reached from `observe/2` →
  `evaluate/4`. The cwd a checker runs in is `context.workspace`, built by
  `provider_context/2` from `data.workspace` (the agent's working copy). That is
  the single seam; there is no other path a predicate is evaluated through.

- **Separate-process rung — already held.** The command-runner providers
  (`Kazi.Providers.CustomScript` / `TestRunner` / `Ratchet`, all via
  `Kazi.Providers.CommandRunner`) shell out with `System.cmd`, which spawns a fresh
  OS subprocess. That subprocess is distinct from the agent's own `claude -p`
  dispatch (`data.harness.run/3` in `dispatch_agent/2`); the agent cannot introspect
  or monkey-patch a BEAM-spawned port. No change was needed for this rung — it is
  reported as `separate_process` and is always active under enforcement.

- **Clean-tree rung — added at the seam.** When enforcement is active,
  `observe_with_isolation/1` wraps the observation: it prepares a throwaway detached
  worktree at `clean_ref` (`Kazi.Enforcement.Isolation.with_clean_tree/4`, the same
  `git worktree add --detach` pattern `Kazi.Ratchet.resolve_git_ref/3` uses,
  candidate-overlaid per the H1 fix below) and evaluates the **guard + held-out**
  predicates (the tamper-prone graders) against it, removing it after. The ordinary
  visible predicates still evaluate against the working copy. So the seam ADR-0042
  §1 assumed exists and is clean; the realization is SCOPED to the graders, not all
  checkers, which is the honest reading of §1(a) ("checker definitions and their
  inputs").

- **The reported guarantee is the actual one.** Clean-tree needs a git workspace.
  When that is absent the worktree add fails, isolation **degrades** to the working
  copy, and `:clean_tree` is dropped from the reported guarantees
  (`Kazi.Loop.enforcement_status/1`). `kazi apply --json` therefore shows a partial
  guarantee, never a fabricated one — the precondition's honesty bar.

- **Landmine.** The clean tree is a temp-dir worktree, always removed in an `after`,
  never the shared working dir (lore L-0014: a sibling session can reset the shared
  tree).

## H1 fix (deep-review 001, 2026-07-03): candidate-graded clean tree

`docs/deep-reviews/001-full-codebase.md` H1 found that grading the ENTIRE clean-tree
cwd wholesale — the original T32.4 realization above — made a held-out/guard
predicate structurally unable to converge: the fix under test lives in the agent's
working copy, but the isolated checker read frozen `clean_ref`, and the only commit
path (`integrate`) is itself gated on the same held-out check passing. A valid
configuration could loop forever, dispatching an agent whose fix the checker would
never see.

The fix: `Kazi.Enforcement.Isolation.prepare/3` now OVERLAYS the agent's candidate
working-tree state (tracked edits + untracked new files) onto the clean worktree
before the checker runs, then re-pins ONLY the configured `read_only_paths` — the
grader's OWN definition files — back to `clean_ref`. This keeps both properties §1
actually needs: a working-copy edit to the *candidate* fix IS seen (so a held-out
predicate can converge once satisfied, without waiting for a commit), while a
working-copy edit to a *grader* file still cannot change the verdict (it stays
pinned to the committed state). See `Kazi.Enforcement.Isolation`'s moduledoc for the
overlay/pin mechanics and `test/kazi/enforcement/isolation_working_tree_test.exs`
for the regression coverage (both properties, plus the graceful-degradation path,
unchanged).

One behavior change operators should know: a grader/checker file is now protected
from clean-tree overlay ONLY if it is listed in `read_only_paths` — a file NOT
listed is overlaid with its working-copy state like any other candidate file. Before
this fix, EVERY file was implicitly pinned (too strong, and the root cause of H1).
An operator who wants a checker script protected from both the read-only-write flag
(guarantee 2) and clean-tree overlay (guarantee 1) lists it once, in
`read_only_paths` — one coherent "this is the grader" declaration instead of two
different implicit ones.

## Diff-inspection guard (T32.5, §5 realized — ADVISORY)

The §5 diff-inspection guard shipped as `Kazi.Enforcement.DiffGuard` (a pure scanner)
wired into `Kazi.Loop`'s post-dispatch path. The realization, faithful to "start
advisory — surface, don't block":

- **Input.** `git diff HEAD` of the workspace — the agent's uncommitted iteration
  changes — fetched via an injectable `diff_fn` (a test feeds a canned diff; a
  non-git/missing workspace or a crashing diff source degrades to "" → no events, so
  the advisory guard can never break the tick). New untracked files are not in
  `git diff HEAD`; the guard inspects edits to existing files, which is where the
  skip/special-case/grader signatures land.

- **Signatures.** `skip_marker` (newly-added skip/xfail/ignore/disabled markers
  across pytest/unittest/JS/Go/Rust/JUnit/ExUnit), `test_special_casing`
  (`if <input-ish ident> == <literal>`, anchored to a small input-ish identifier
  allowlist so a routine `if mode == "create"` branch is not flagged), and
  `grader_edit` (an add/delete touching a `read_only_paths` grader path or an
  obviously-named predicate file). Only ADDED lines carry the first two; `grader_edit`
  also fires on a deletion.

- **The downgrade.** A hit (a) appends a `diff_gaming` event to the loop's
  `gaming_events` (surfaced in `--json` alongside the §2 read-only-write flags), and
  (b) records the upcoming observation index so `Kazi.Loop.code_history/1` discounts
  that observation's graded SCORE before the stuck classifier reads it. A GAMED
  apparent score improvement therefore no longer rescues the loop from a stuck
  verdict (ADR-0041's graded gradient). The boolean failing-set/`:converged` logic is
  untouched and the stored vector keeps its real score, so a genuine convergence is
  never blocked — only the *progress view* is downgraded, exactly the ADVISORY
  contract the "Consequences" false-positive risk demands.

## Authoring default for self-hosting goals (T45.10, #1669)

The T45.10 exit-proof dogfood (2026-07-21) found that `kazi plan` authored NO
`[enforcement]` block at all, so a goal targeting kazi's own repo left the
dispatched agent free to edit the very provider file that grades one of its own
predicates — and, in the dogfood, it did (a legitimate fix, merged as #1663, but
nothing in the system distinguished it from one that was not).

`Kazi.Authoring.SelfHost.default_read_only_paths/2` now fills that gap AT
AUTHORING TIME, not by changing this ADR's decision: when a drafted goal carries
no authored `[enforcement]` block AND its workspace is kazi's own source tree,
`read_only_paths` defaults to the provider file(s) implementing the goal's OWN
predicate kinds — never the whole engine, so kazi's routine self-improvement of
an unrelated provider is not additionally flagged. A goal that already authors
an `[enforcement]` block (of any shape, including `enabled = false`) is left
completely alone; this only fills a true absence. See `docs/self-hosting.md`
("Authoring pitfalls when `kazi plan` targets kazi itself").

## Alternatives rejected

- **Keep guards declarative (today).** A capable model defeats convention; the METR
  43x and the Anthropic grader-rewrite result show this is not hypothetical. The whole
  product is undermined if "done" is gameable.
- **Sandbox the agent so hard it can't touch tests at all (global read-only repo).**
  Breaks legitimate test-authoring in creation mode (the agent SHOULD write new tests).
  The read-only class is scoped to the goal's PREDICATE/acceptance files, not all
  tests.
- **Hide ALL predicates from the agent.** Removes the climbable gradient and the fix
  evidence (ADR-0041) — the loop converges far slower. Only the acceptance subset is
  optionally held out; the working predicates stay visible.

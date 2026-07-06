# Integrate discipline (issue #819)

`Kazi.Actions.Integrate` is the `:integrate` action: it lands a converged
change (branch → commit → push → open PR → rebase-merge). A live firing of
this action once committed ~1800 untracked-but-unignored machine-local files
onto a public repo's default branch via a blind `git add -A`, and merged the
PR seconds after opening it, before CI ran (issue #819, following the
`.gitignore` hardening in #818). Three guardrails close that gap.

## Scoped staging

A goal that declares `[scope] paths = [...]` in its goal-file gets strict
staging: tracked modifications are staged everywhere (`git add -u`, which can
never introduce a new untracked file), and only the explicitly declared paths
are staged for untracked content. An untracked file that lives outside those
declared paths is never staged, and therefore never committed or landed on
the default branch. A goal with no declared scope paths keeps the prior
whole-workspace `git add -A` behavior — this is the backward-compatible
default; declaring `paths` is how a goal opts into the stricter guard.

## Merging waits for CI

Merging waits for CI: the default integrator (`GhIntegrator`) blocks on `gh
pr checks --watch` before it will merge a pull request, so `kazi integrate`
never lands a change before its required checks resolve one way or the
other. This is the direct fix for the #819 incident, where the PR was
rebase-merged before CI had a chance to run.

Opt out of the wait with `params[:wait_for_checks] = false` on the
`:integrate` action if the target repo has no configured checks to wait on
before a merge lands. The opt-out is explicit and per-action; the default is
always to wait.

## Informative commit message and PR title

The default commit message and PR title/body always carry the goal's id and
name plus the list of predicates that converged, never a bare "land
converged change" — so a reviewer looking at `git log` or the PR list can
tell what landed and why without cross-referencing a run id.

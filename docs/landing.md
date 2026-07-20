# Landing: `[integration]`, `[conventions]`, and the process contract

Convergence is not the end of the story. A goal whose code predicates all pass but
whose fix is still sitting uncommitted in a worktree is **not done**. This is the
E44 "landing is part of convergence" arc (ADR-0055): kazi treats committing,
pushing, opening a PR, and merging as part of the objective bar, and it owns the
universal *how to work* rules so goal-files stay declarative.

This doc teaches three things:

1. the `[integration]` and `[conventions]` blocks, and the controller-owned
   process contract;
2. the **Tier-0 pattern** — an explicit `landed` `custom_script` predicate for
   goal-sets running on OLDER kazi binaries that predate the `[integration]` block;
3. the ADR-0055 **routing decision** — which concern belongs where, so you never
   paste prose discipline blocks into a goal-file.

## 1. `[integration]`, `[conventions]`, and the process contract

### `[integration]` — how converged work LANDS (ADR-0055)

```toml
[integration]
mode = "commit"   # one of: none | commit | branch | pr | merge
```

`mode` (default `none`) declares how far converged work should land:

| `mode`   | lands | passes when |
|----------|-------|-------------|
| `none`   | nothing (converge-and-stop) | — |
| `commit` | committed on a non-base branch | clean tree + a commit on a non-base branch |
| `branch` | + pushed | the above, plus the branch is pushed (has an upstream / is on `origin`) |
| `pr`     | + PR opened | the above, plus an OPEN PR exists against the base |
| `merge`  | + rebase-merged | the branch's PR is rebase-merged (never squash, never a merge commit) |

When `mode != none`, the loader **synthesizes a `landed` predicate** (T44.2) and
appends it to the vector. `landed` is an ordinary, visible predicate evaluated
against the LIVE working tree: it asserts a clean tree PLUS the mode-appropriate
state above. So "code-green with the fix still uncommitted" stays an UNSATISFIED
vector — the loop keeps going, and the failing `landed` evidence (the dirty file
list, the unpushed branch) drives the next dispatch.

The `:integrate` action then **verifies-then-ships** (T44.3): the inner agent owns
its own commits during the loop; `Integrate` does NOT bulk-commit. It verifies a
clean, committed, non-base branch, pushes, opens the PR with the converged
predicate vector as the body, and rebase-merges. A dirty tree at integrate time is
a distinct error (never a silent bulk commit) that re-dispatches the agent to
commit.

Under `--parallel` (T44.10) the same landing runs **per group**: each converged
partition lands on its own group-derived branch and the collective result carries
per-partition `landed: {branch, pr, merge_commit}` refs (see
`docs/schemas/collective-result.md`). For `mode = "merge"` over a `needs`-DAG
(T44.11), the group branches rebase-merge in topological order — a group merges
only after every `needs` ancestor merged — and after each merge `git cherry`
verifies every previously-merged group's patch still survives; a silently-dropped
hunk HALTS the landing naming both groups.

Optional `[integration]` keys: `branch` (the run's real target branch; absent →
`task/<sanitized id>`), `branch_prefix`, `base`, `commit_style`. `kazi schema
integration` documents the shape.

### Exit-code semantics: `--strict-landing` (issue #1407)

The `[integration]`/`landed` predicate above governs the **worktree-isolated
serial `kazi apply`** path's own post-convergence landing step (T50.2, ADR-0065
decision 2) — separate from a goal-file's own `[integration] mode`. By DEFAULT
`kazi apply`'s exit code mirrors **convergence alone**: a run that converged but
whose landing step failed to rebase-merge the task branch onto the base still
exits `0`. The failure is never hidden — the result's `integration.landed ==
false`, the failure reason, and the surviving task branch (the worktree teardown
never destroys it) are all still reported, plus a stderr warning — but the exit
code alone does not distinguish "converged and landed cleanly" from "converged,
landing hiccupped".

Pass `--strict-landing` to couple the exit code back to the landing verdict, the
pre-#1407 behavior: a converged-but-unlanded run then exits `1`, for a caller
(e.g. a CI merge gate) that wants a landing failure to fail the invocation
outright. `--strict-landing` has no effect when landing succeeds, or on an
in-place run (there is nothing to land).

### The terminal report names WHERE the work landed (issue #1550)

A converged run's **human report** ends with a `landed:` line naming the branch
the work landed on and the base it integrated onto, e.g.

```
landed: task/adopt-widgets → main (commit 0e3e8ba0c1d2)
```

so an operator is never left thinking a `converged` run did nothing when its
commits went to a kazi-owned branch (`task/…`, `kazi/integrate-…`) while the
checkout looked clean. A converged-but-unlanded run instead prints a loud `NOT
LANDED:` line naming the surviving task branch and the reason. The same facts are
on the `--json` surface's `integration` object (`landed`, `base`, `task_branch`,
`refs`); the human line is additive. An in-place run (nothing to land) prints
neither.

The landing commit/PR message itself names the **real goal id, goal name, and
converged predicates** — the serial-landing path threads the goal and the
converged predicate vector into the integrator, so the commit reads
`integrate(<goal-id>): <goal name> [<predicates>]` rather than the pre-#1550
`integrate(unknown-goal): converged change [(none recorded)]`.

### `[conventions]` — the controller-owned process contract (ADR-0055 decision 4b)

```toml
[conventions]
process_contract = true              # default; false disables the section entirely
extra_rules = ["Run mix format before committing."]
```

kazi owns a small, versioned **PROCESS CONTRACT** — universal working rules
appended to every dispatch prompt after the orientation prefix, before the work
item (T44.4). It is rendered from `[conventions]` config ALONE (never per-iteration
state), so it is byte-identical across a goal's iterations — a cacheable head at
near-zero marginal token cost — and harness-agnostic, so an `opencode`/`codex`/
`gemini` agent that never sees a `CLAUDE.md` still gets the rules. The universal
rules are: small conventional commits scoped to one directory; commit as you go on
the goal branch; no stubs; grep `docs/lore.md` before debugging; migration-number
safety under parallelism; network-retry expectations; prefer graph tools when a
code graph is present.

`process_contract = false` disables the section (the prompt reverts byte-identically
to the pre-E44 body). `extra_rules` appends repo-specific lines VERBATIM after the
universals — the only sanctioned way to extend the contract. Repo-specific style
otherwise stays in the repo's own `CLAUDE.md`/`AGENTS.md`; the contract carries
only universals, to avoid double-carrying.

### How a `plan → approve → apply` proposal lands (T45.11, #1620)

The single-goal proposal chain honors `[integration]` the SAME way a goal-file
does — the proposal parser (`Kazi.Authoring.parse_proposal/2`) reuses the goal-file
integration parser, and the block round-trips through the persisted proposal. So a
drafted proposal that carries an integration block lands on `kazi apply
<proposal-ref>`:

```json
{
  "predicates": [ ... ],
  "integration": { "mode": "pr", "base": "main" }
}
```

For an **already-approved** proposal (or a goal-file) that declared no
`[integration]`, override the landing mode at apply time — no re-authoring:

```
kazi apply <proposal-ref> --integration pr --base main
```

`--integration <none|commit|branch|pr|merge>` sets the goal's landing mode (and
`--base` the target branch); `SerialLanding` / `Integrate` then land the converged
work. Declaring `[integration]` in the goal-file or proposal is the primary path —
it also synthesizes the `landed` predicate that gates convergence on the work being
committed; the flag is the lighter, explicit override for landing without editing
the goal. Before #1620 neither existed for the single-goal chain: the proposal
parser dropped the block, the converged goal defaulted to `mode :none`, and
`SerialLanding` returned `:nothing_to_land` — no branch, no PR.

## 2. The Tier-0 pattern: a hand-written `landed` predicate

If your goal-file targets a kazi binary that PREDATES the `[integration]` block,
`mode` is unknown and no `landed` predicate is synthesized. Author the equivalent
by hand as a `custom_script` predicate — this is the **Tier-0 pattern**: it checks
"clean tree AND HEAD ahead of `origin/main`", the manual equivalent of
`[integration] mode = "commit"`. Keep the commits that satisfy it **small and
scoped to a single directory** (the same convention the process contract teaches,
so the two stay consistent).

Copy-pasteable, and it loads through the real goal-file loader as-is:

```toml
# Tier-0 landing check: for a kazi binary that predates the [integration] block,
# hand-write the `landed` predicate that `mode = "commit"` would synthesize. It
# passes only when the tree is CLEAN and HEAD is AHEAD of origin/main (the work is
# committed, on a branch, ready to land). Keep the commits small and scoped to one
# directory, matching the process contract.
id = "tier0-landing-example"
name = "Tier-0 manual landed predicate"

[[predicate]]
id = "tests"
provider = "custom_script"
description = "the suite passes"
cmd = "sh"
args = ["-c", "true"]
verdict = "exit_zero"

[[predicate]]
id = "landed"
provider = "custom_script"
description = "clean tree AND HEAD ahead of origin/main -- manual equivalent of [integration] mode = commit on binaries without the block"
cmd = "sh"
args = ["-c", "git status -s | grep -q . && exit 1; git diff origin/main HEAD | grep -q . || exit 1; exit 0"]
verdict = "exit_zero"
```

`kazi` passes `args` to the executable VERBATIM (no shell/env expansion), so the
compound check runs under `sh -c`. On a binary that DOES support `[integration]`,
drop this predicate and declare `[integration] mode = "commit"` instead — kazi
synthesizes the equivalent for you and the `:integrate` action lands it.

## 3. The routing decision (ADR-0055 decision 4): what goes where

Goal-files are reviewable declarative contracts — "what is true when done". Do NOT
paste orchestrator-style prose discipline blocks into them; that reintroduces the
subjective layer kazi exists to remove. Each concern has ONE home:

- **Objectively checkable → predicates.** Commit discipline (the `landed`
  predicate), the validation ladder (tests/format/lint), zero-stub, docs-with-code,
  OSS hygiene. These are DATA (predicates), not prose.
- **How-to-work guidance → the process contract** (`[conventions]`, decision 4b).
  The universal working rules above are versioned WITH kazi and appended to every
  dispatch — you do not restate them per goal. Repo-specific style goes in the
  repo's own `CLAUDE.md`/`AGENTS.md`, not the goal-file.
- **Mechanical orchestration → controller behavior, not words.** Worktree
  isolation, working-directory pinning, branch creation, merge ordering, and PR
  opening are kazi's job (the scheduler + the `:integrate` action). You declare
  `[integration] mode`; kazi performs the mechanics.

So the migration is: a discipline block that is *checkable* becomes a predicate; a
*universal working rule* is already carried by the process contract; and
*mechanics* are the controller's behavior. A goal-file stays a short, declarative
statement of done.

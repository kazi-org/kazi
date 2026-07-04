# ADR 0055: Landing is part of convergence — the `[integration]` block, the implicit `landed` predicate, and the controller-owned process contract

## Status
Accepted

## Date
2026-07-03

## Refines / depends on
ADR-0002 (goals are predicate sets), ADR-0026 (kazi under an external pool —
the interop posture this ADR partially subsumes), ADR-0027 (the native
scheduler), ADR-0031 (`kazi apply` subsumes the outer loop — the subsumption
claim this ADR makes honest), ADR-0034 (docs-with-code + no-internal-leak
gates), ADR-0042 (anti-gaming enforcement), ADR-0052 (self-teaching artifacts
must not assume a personal skill library). Supersedes nothing; it closes the
gap ADR-0031 left open.

## Context

Operators who moved from a generic plan→apply orchestration workflow (an
orchestrating agent dispatching sub-agents with prescriptive prompts) to
`kazi plan` → `kazi apply` lose a set of conveniences that the generic
workflow provided for free. The sharpest loss, observed in live parallel
dogfoods: **converged goals leave dirty worktrees — nothing commits**. With N
parallel groups this makes coordination manual and error-prone; the operator
inherits N uncommitted trees to reconcile by hand.

The root cause is structural, not an inner-model failure. `Kazi.Loop.decide/2`
orders its clauses: (1) whole vector satisfied → `:converged`; (2) code
predicates failing → dispatch; (3) not landed → `:integrate`; (4) not deployed
→ `:deploy`. A goal whose predicates are all code-kind (tests, format,
`custom_script`) satisfies the whole vector the moment code goes green, so
clause 1 terminates the loop before clause 3 is ever reachable. The
`:integrate` action (branch → commit → push → PR → rebase-merge) only fires
when a **live** predicate keeps the vector unsatisfied past the code-green
point. Landing is therefore an accident of goal composition, not a property of
convergence.

Two secondary gaps compound it:

1. **`Kazi.Actions.Integrate` commits as a monolith.** It runs `git add -A`
   plus ONE generated commit ("fix: land converged change"). That violates the
   small-scoped-commit discipline the repo itself mandates (many small commits;
   never files from different directories in one commit) and produces
   unreviewable history.

2. **The dispatch prompt carries no process contract.** The inner agent
   receives only `goal=<id> fix failing predicates: <ids>` plus evidence.
   None of the working discipline a prescriptive orchestrator gives its
   sub-agents — commit-as-you-go in small conventional commits, zero-stub
   policy, lore-grep before debugging, migration-number safety under
   parallelism, network retry, graph-aware exploration — reaches the agent
   from kazi. (A repo's own `CLAUDE.md`/`AGENTS.md` reaches SOME harnesses,
   but that is per-repo luck and per-harness behavior, not a kazi guarantee.)

There is also a permission landmine: a headless Claude harness under
`acceptEdits` denies `git commit` unless the goal's `[harness]`
`permission_mode`/`allowed_tools` allow it — so even a willing inner agent may
be silently unable to commit, and the denial is invisible without the
`permission_denials` surfacing (#769) and the `[harness]` permission wiring
(#776).

Finally: ADR-0031's claim that `kazi apply --parallel` subsumes an external
pooled orchestrator cannot be true while the external pool lands branches/PRs
and kazi does not. This ADR is the missing half of that claim.

## Decision

**1. An `[integration]` goal-file block declares how converged work lands.**

```toml
[integration]
mode = "pr"            # commit | branch | pr | merge | none (default: none)
branch_prefix = "kazi/" # optional; default "kazi/"
base = "main"           # optional; default: detected from origin
commit_style = "conventional"  # optional; documented, informational
```

Modes: `commit` (clean tree, committed on a branch), `branch` (committed AND
pushed), `pr` (pushed AND a PR is open against base), `merge` (PR
rebase-merged — the house rule; never squash, never a merge commit), `none`
(today's behavior, byte-identical). The default is `none` in the current major
version — flipping the default is a breaking change reserved for the next
major (the v2.0.0 landmine). The `kazi plan` clarify floor flags a code goal
with no `[integration]` block the same way it flags a missing
live-verification predicate: surfaced in the proposal, never silently
accepted.

**2. Landing is enforced as an implicit `landed` predicate, not a decide/2
special case.** When `mode != none`, the loader appends a synthesized
`landed` predicate to the vector (clean tree + mode-appropriate git/GitHub
state, checked deterministically). The objective-termination guard (T0.8) is
untouched: "the work is landed" simply becomes part of the objective bar, so
a code-green-but-dirty workspace is an UNSATISFIED vector and the loop keeps
driving — the failing `landed` predicate's evidence (the dirty file list, the
unpushed branch) is exactly the dispatch context that tells the inner agent
what to do. This is the kazi-native mechanism; no prose exhortation to commit
can be gamed or forgotten when the bar itself requires it. Until this ships,
the SAME pattern works today as an explicit authoring convention: a
`custom_script` `landed` predicate in the goal-set (Tier 0; the self-teaching
artifacts document it).

**3. `Kazi.Actions.Integrate` stops committing for the agent.** The
`git add -A` monolith is removed for `[integration]` goals. The inner agent
owns its commits (per decision 4); Integrate VERIFIES a clean, committed
branch and then only pushes, opens the PR (body = the predicate vector and
iteration evidence — an auto-generated verification report), and
rebase-merges per mode. A dirty tree at integrate time is a failing `landed`
predicate → re-dispatch with "commit your work" evidence, never a silent bulk
commit. (Goals without `[integration]` that reach `:integrate` via live
predicates keep the legacy behavior until the next major.)

**4. kazi owns a versioned, controller-side PROCESS CONTRACT in the dispatch
prompt — and goal-files stay declarative.** We considered embedding the
orchestrator-style discipline blocks (~15 of them) into `kazi plan` output so
each goal-file carries them. **Rejected.** Goal-files are reviewable
declarative contracts ("what is true when done"); per-goal prose process rules
would drift, bloat every proposal, and re-introduce the subjective layer kazi
exists to remove. Instead each block routes to one of three homes:

   a. **Objectively checkable → predicates.** Commit discipline (`landed`,
      decision 2), validation ladder (already predicates: tests/format/lint),
      zero-stub, docs-with-code, OSS hygiene (decision 6). The clarify floor
      and the `/plan`-style bridges SUGGEST these; they are data, not prose.

   b. **How-to-work guidance → a stable process-contract section** appended to
      the orientation prefix of every dispatch: small conventional commits
      scoped to one directory, commit as you go on the goal branch, zero-stub
      policy, grep `docs/lore.md` before debugging, migration-number safety
      (derive sequence numbers from origin under parallelism), network-retry
      expectations, prefer graph tools when a code graph is present. The text
      is versioned WITH kazi (updated by release, not per goal), identical
      across iterations (cacheable head, near-zero marginal token cost), and
      harness-agnostic (parity for opencode/codex/gemini agents that never see
      a `CLAUDE.md`). A `[conventions]` block can extend or disable it
      (`process_contract = false`); repo-specific style stays in the repo's
      own `CLAUDE.md`/`AGENTS.md` — the contract carries only universal rules
      to avoid double-carrying.

   c. **Mechanical orchestration → controller behavior, not words.** Worktree
      isolation, working-directory pinning, branch creation, merge ordering,
      PR opening are kazi's job (scheduler + Integrate). We do not instruct an
      agent to do what the controller does deterministically.

**5. Under `--parallel`, each group lands as its own branch/PR.** Small
blast-radius PRs are the scoped-commit convenience at PR granularity. The
`needs` DAG the scheduler already computes IS the merge order (strictly better
than heuristic dependency sorting). After each group's rebase-merge, a
`git cherry` verification confirms no group's patch content was silently
dropped. The collective result gains per-group `landed` refs
(`{branch, pr, merge_commit}`), and `kazi status` surfaces them — the
"what landed where" coordination surface.

**6. Three deterministic gate providers ship first-class:** `no_stubs`
(diff-scan for stub/placeholder/hardcoded-return patterns reachable from
production code), `oss_hygiene` (diff-scan for private IPs/hostnames, personal
paths, internal codenames — the ADR-0034/E29 CI guard exposed as a predicate),
and `docs_updated` (a surface-changing diff must touch docs or carry an
explicit `[no-docs]` marker). These make the external orchestrator's wave
gates kazi-native: objective predicates, suggested by the clarify floor for
engineering goals, never prose review.

**7. `kazi apply` runs a PREFLIGHT before first dispatch** (skippable with
`--no-preflight`): base suite green on the starting ref, `gh auth status` OK
when mode needs GitHub, `git push --dry-run` works when mode pushes, no stale
kazi worktrees. Refuse to dispatch into a broken base — a mid-run auth expiry
or broken push path strands every partition.

**8. Permissions align with the declared mode.** When `mode != none` and the
harness is permission-managed (claude), the default `allowed_tools` include
the git operations the mode requires (`git add/commit/push`, `gh pr` for
`pr`/`merge`), and `kazi lint` warns when an explicit
`permission_mode`/`allowed_tools` combination would deny them (builds on
#776/#769).

**Non-goals.** Subjective review lenses (security/quality/performance prose
review), content/strategy verification profiles, and fix-loop heuristics stay
in orchestration-layer skills. kazi's differentiator is that truth lives in
the predicate vector; anything worth gating on enters as a deterministic
provider or stays upstream.

## Consequences

Positive: converged work is always committed, pushed, and reviewable — the
no-commit coordination failure disappears by construction; the termination
guard stays the single source of truth (landing is a predicate, not a side
path); parallel runs produce small per-group PRs in dependency order with
silent-revert verification; the discipline that made prescriptive
orchestration pleasant is carried by the controller once, versioned,
cacheable, and harness-independent; ADR-0031's subsumption claim becomes
provable.

Negative / costs: the `landed` predicate interacts with clean-tree isolation
enforcement (ADR-0042) — checkers that require a clean tree must run against
the committed state, and the held-out-predicate deadlock class (H1) must stay
regression-tested; `merge` mode gives an agent-adjacent pipeline the power to
land on the default branch, so it should be reserved for goals whose predicate
set includes the repo's full CI-equivalent bar; the process contract adds a
stable ~½–1 KB to every dispatch prompt (mitigated: cacheable head);
`default = none` means existing goals keep the old behavior and authors must
opt in until the next major.

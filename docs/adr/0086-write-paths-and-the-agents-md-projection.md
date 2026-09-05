# ADR 0086: `write_paths` as declared scope, and the per-directory AGENTS.md projection

## Status

Accepted (operator, 2026-09-05, after review by the chief and chief-architect
sessions; their positions are recorded under Alternatives rejected)

## Date

2026-09-05

## Refines

ADR-0002 (`[scope]`, `write_paths` from #860), ADR-0065 (§3 overlap
inference, §5 worktree indirection), ADR-0080 (what is sealed), ADR-0082
(generated views), ADR-0085 (`[scope]` guard enforcement).

## Context

A dispatched agent's prompt today is assembled by kazi from the goal-file:
goal name, brief, failing predicates, evidence (`kazi/AUTHORING.md`). That
prompt reaches the agent only through the dispatch channel. An operator who
opens a harness by hand inside `pkg/foo` to work on the goal that owns
`pkg/foo` gets none of it; they get whatever `CLAUDE.md`/`AGENTS.md` files
the harness finds walking up from the working directory, which is repo-wide
convention text, never the goal's acceptance contract.

Harnesses read instruction files hierarchically: Claude Code walks up from the
working directory merging every `CLAUDE.md` it finds; Codex does the same for
`AGENTS.md`. That walk-up is the natural delivery channel for "the context
this directory needs and nothing more": a file at the goal's scope root is
read by every agent working under it, and by no agent working elsewhere.

The goal-file already declares where a goal works. `[scope]` carries `paths`
(a coarse read allow-list), `write_paths` (the editable subset, consumed by
`Kazi.CollateralReport`), and `deny` (never-touch paths, enforced as a
`:scope_guard` predicate) -- `lib/kazi/scope.ex`. A first draft of this ADR
added a fourth list, `owned_paths`; it was cut because "the subtree this goal
builds" and "the subtree this goal may edit" are the same declaration, and two
fields with one meaning can disagree.

Three things kazi already decided constrain how the walk-up channel can be
used:

- ADR-0080 seals the INPUTS to the acceptance contract. A worker in one
  consumer project loosened its own thresholds to reach green; a reconcile
  loop whose bar is writable by the reconciler has no termination guarantee.
  A file the agent is told to read, in the directory the agent is told to
  edit, is exactly such a bar unless something makes it non-authoritative.
- ADR-0082 landed the roadmap render as a generated view BESIDE the WBS, not
  in place of it, because the read-model does not hold the fidelity a
  replacement would need. The pattern generalizes: authored tables are
  authoritative, a render is a projection.
- ADR-0085 made the `[scope]` block the one declarative channel that reaches
  the grind model, with `forbidden_paths` enforced as a guard predicate.
  kazi enforces what is declared; it does not infer intent.

Two measured costs also bound the design. In a sibling repo, 8 of 14 open PRs
were edits to a committed status file that regenerates on state change; any
tracked artifact that changes per grind iteration recreates that collision.
And a containerized fleet lane receives its task contract through exactly one
prompt channel, assembled and validated on the dispatcher host at a pinned
task sha (a checkpoint `prompt.md` on a bind-mounted lane; a `TASK_PROMPT`
object on a fresh-clone cloud canary). The read-model lives on the host, and
the canary image carries no kazi binary, so nothing can be rendered inside a
container at dispatch time.

## Decision

1. **`write_paths` is the declared scope; no new field.** A goal's scope
   roots are its `[scope].write_paths`, falling back to `[scope].paths` when
   `write_paths` is empty. Absent both, nothing in this ADR applies to that
   goal. This is exactly the field preference `Kazi.Fleet` already applies
   for ADR-0065 §3 overlap inference (`write_paths`, else `paths`), so the
   projection and the fleet scheduler read one declaration. This ADR adds
   no second overlap rule and does not restate the existing one. One
   behavior change to the existing rule, recorded here because §3 says
   "overlap" and the implementation says string prefix: overlap is computed
   on the expanded globs, so `pkg/foo/**` and `pkg/foobar/**` do not
   collide. The existing treatment of an unscoped goal -- no inferred edges,
   because the alternative serializes the whole fleet on the first unscoped
   goal -- stands; a goal that must serialize declares scope or
   `depends_on`.

2. **Nested scope roots are forbidden in v1 for goals that render.** Across
   the goals kazi can see together (a fleet, or one `--tree` render), scope
   roots are disjoint and each root carries at most one goal. `kazi plan
   lint` and `kazi plan render --tree` refuse otherwise, naming both goals
   and the shared root. Rationale: with the walk-up, an agent in
   `pkg/foo/bar` reads every ancestor node, so a goal rooted at `pkg/foo` and
   a goal rooted at `pkg/foo/bar` would prompt the child's agent with the
   parent's brief. Nesting with explicit inheritance semantics is a
   follow-up ADR if a real goal ever needs it.

3. **The node render is a pure function, and nothing it produces is ever
   committed.** `render(goal.toml, scope root, observe result) -> node
   content`: the goal's brief, its predicate definitions, the currently
   failing predicates, and their evidence, under the generated banner
   ADR-0082 uses. It reads `goal.toml` and an observe pass only, never the
   host read-model registry, so any host that has the goal-file and the kazi
   binary can re-derive it byte-for-byte. Goals with no scope render
   nothing; the repo root is never a render target and holds repo
   conventions only.

4. **Two delivery adapters, one renderer.**
   - *Interactive tree.* `kazi plan render --tree` writes the node to
     `<scope-root>/AGENTS.md` as an ignored, untracked file so the harness
     walk-up reads it; `kazi apply` regenerates it before dispatch. Per
     ADR-0065 §5 it routes through the same worktree indirection as every
     other `plan render`. The harness walk-up reads untracked files, so
     the operator's `cd pkg/foo` case works after one render.
   - *Dispatched lane.* The dispatcher renders on the host at the pinned
     task sha and embeds the node in the prompt channel the lane already
     has (the checkpoint `prompt.md`, or the `TASK_PROMPT` object for a
     cloud canary). Nothing renders inside the container, no tree is
     mounted in, and the walk-up is irrelevant there: the whole parent
     chain is one rendered string. The container needs no kazi binary for
     delivery; a lane image that carries one uses it for `--check`
     verdicts only.

5. **The render is a projection, not an authority. Tamper protection is
   freshness plus `forbidden_paths`, not sealing.** ADR-0080 sealing stays on
   `goal.toml`; a derived artifact is never sealed, because two sealed
   authorities with no tiebreak is worse than one. Freshness instead:
   (a) interactive, at run start and at each observe pass kazi re-renders
   from `goal.toml` and byte-compares against the file in the worktree, a
   mismatch fatal to the run the way an ADR-0080 mismatch is; (b) in a lane,
   the dispatcher records the rendered content's sha256 in the lane
   contract beside the task sha, and the in-container `kazi apply --check`
   re-renders from `goal.toml` at that sha and fails on mismatch. And (c)
   every rendered path is added to the goal's effective `forbidden_paths`
   automatically, so the ADR-0085 guard refuses a commit that edits the
   agent's own prompt. Sealing `goal.toml` plus freshness on its projection
   closes the ADR-0080 gap without a second contract.

6. **The generator never edits, overwrites, or shadows a hand-written file.**
   If `AGENTS.md` exists at a scope root and lacks the generated banner,
   `--tree` fails naming the path; the operator moves the content. Where no
   `CLAUDE.md` exists at the root, kazi creates a `CLAUDE.md -> AGENTS.md`
   symlink so Claude Code's walk-up reads the node; where a hand-written
   `CLAUDE.md` exists, kazi leaves it alone and the failure message tells the
   operator to add an `@AGENTS.md` include line by hand. Whether each
   harness's walk-up follows the symlink is asserted by a test in the
   implementing task, not by this ADR.

7. **`kazi apply --cwd <scope-root>`** launches the harness inside the scope
   root so the walk-up supplies exactly the parent chain. It defaults to the
   goal's first scope root when one is declared.

## Consequences

**Positive:**
- An operator can `cd pkg/foo` and open a harness by hand and get the goal's
  brief and predicates through the channel the harness already reads; a
  dispatched agent gets the same node in its prompt.
- Parallelism in a fleet becomes a declared property (disjoint scope roots)
  instead of an operator judgment, using the ADR-0065 rule that already
  exists and the `[scope]` field that already exists.
- The tamper story stays single-authority: `goal.toml` sealed, its projection
  unwritable and freshness-checked.

**Negative / accepted trade-offs:**
- Nothing human-readable lands in the repo: a fresh clone has no node until
  someone runs `kazi plan render --tree`. Accepted over a committed stable
  file because that bought only readability at the cost of two mechanisms.
- Lane dispatchers gain a render step and a sha in their contract; that is
  a dispatcher-class change in each fleet repo, reviewed there.
- Disjoint-roots-only means a goal that genuinely spans two subtrees declares
  both roots and gets two identical nodes, or declares their common parent.
- `forbidden_paths` enforcement is the ADR-0085 guard, which refuses the
  commit; an agent can still overwrite the file in its working tree during a
  run. The freshness check at the next observe pass catches that and fails
  the run, so the window is one iteration and the outcome is visible.

## Alternatives rejected

- **A new `[scope].owned_paths` field.** The first draft. Cut: `[scope]`
  already has `write_paths` with the same meaning, and a fourth path list
  that must be kept consistent with the third is a lint nobody asked for.
- **An unscoped goal overlaps every scoped goal.** Proposed by the chief
  session. Rejected: `Kazi.Fleet` deliberately gives an unscoped goal no
  inferred edges because the alternative halts fleet parallelism on the
  first unscoped goal, worktree-per-goal (ADR-0065 §1) already bounds the
  blast radius to an integration conflict, and it would be a second overlap
  rule beside §3.
- **Seal the rendered brief section (ADR-0080 style).** Proposed by the chief
  session. Rejected: it creates a second sealed authority, and "which wins
  when they differ" has no good answer. Freshness plus `forbidden_paths`
  reaches the same guarantee with `goal.toml` as the only authority.
- **Commit the stable part (brief, predicate definitions), inject the
  volatile part at dispatch.** Held at one point by both reviewing sessions,
  withdrawn by both against the lane code: on a bind-mounted lane the
  injected file is dirty state the watchdog checkpoint-commits, and on a
  fresh-clone canary the host cannot write into a clone that does not exist
  yet, so injection becomes a second renderer in the entrypoint. Two
  renderers is the failure mode.
- **Render inside the container.** Rejected: the cloud canary image carries
  no kazi binary, and the read-model lives on the host.
- **Mount a rendered tree overlay at the scope root.** Rejected: the
  checkpoint volume carrying the prompt already is that mount; the walk-up
  has nothing to add inside a lane.
- **Project unscoped goals to the repo root.** Rejected: every dispatch
  anywhere in the tree would then read every unscoped goal's brief, the
  opposite of "the file is the prompt".
- **Commit the render, regenerated on state change (the ADR-0082 shape).**
  Rejected on the measured status-file collision cost; ADR-0082 regenerates
  at goal grain, this would regenerate at iteration grain.
- **`kazi adopt` inferring scope from directory ownership.** Cut to its own
  ADR. Inference is a guess, and ADR-0085 says kazi enforces what is
  declared and does not infer intent; the projection decision does not
  depend on it.
- **A neutral filename (`AGENT.md`) injected into the prompt by kazi.**
  Rejected: neither harness reads it natively, which throws away the walk-up
  that motivates the design.

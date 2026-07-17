# kazi — Concept & Architecture

This is the canonical source of truth for what kazi is, why it exists, and how
it is built. Decisions are frozen as numbered ADRs in [`adr/`](adr/); this
document is the narrative that ties them together. Update it when a decision
changes (and write/super­sede the ADR).

---

## 0. How you actually use it (the spine)

Give **Claude Code** the power to actually *finish*. You chat with Claude the way
you already do; kazi works in the background to make "done" **objective** —
looping your agent until every check passes, or stopping to tell you why.
**You never run kazi yourself — Claude does.** A one-time `kazi install-skill`
teaches Claude Code a skill that *drives* kazi for you, and from then on the
adoption spine is:

> **you → Claude Code → kazi → Claude Code.**

Concretely, in Claude Code you drive the skill's two verbs:

```text
/kazi plan "add a /healthz endpoint that returns 200 ok, with a test, deployed"
/kazi apply
```

`/kazi plan` has Claude author the acceptance predicates (glance at them, then
converge); `/kazi apply` runs the reconcile loop until every predicate is
objectively true (or reports `stuck` / `over_budget`). Plain language works too —
just say *"**have kazi drive this until done**"* and the skill runs the same
`/kazi plan` → `/kazi apply` for you. Claude Code reports the result back; you
never leave your chat with Claude.

Under the hood — the part you don't operate directly — kazi is the
**outer/reconciliation loop** the agent drives (Section 1). It is **not** itself
a skill, a harness, or another agent; `install-skill` only writes a Claude Code
*skill* whose job is to drive kazi. The rest of this document is the architecture
beneath that spine.

---

## 1. The one-sentence definition

**kazi is a reconciliation controller for software goals: you declare desired
state as a set of machine-checkable predicates, and kazi drives coding agents in
a loop until actual state matches — or the work is stuck or the budget is spent.**

It is the *outer loop*. The coding agent (Claude Code, Codex, ...) is the *inner
loop*. kazi never replaces the harness; it conducts it.

---

## 2. Why kazi exists (the two gaps)

### Gap 1 — "Done" is the agent's opinion

A coding agent stops when it *believes* it is finished. There is no objective
gate. This is the root of the most common failure in agentic workflows: an agent
reports success on work that is merely *plausible*. Long verification checklists
do not fix it — a subagent that skips a step still reports success.

kazi inverts where truth lives. **Truth lives in the controller, not the agent.**
A goal carries a set of predicates; the loop may only terminate as `converged`
when every predicate evaluates `true` with stored evidence. The agent's job is to
*change the code*; kazi's job is to *decide whether the goal is met*. Neither can
usurp the other.

### Gap 2 — Parallel agents collide

Locking a *task* (mutual exclusion on identity) stops two agents doing the same
task. It does nothing about two agents doing *different* tasks that edit the
*same files* — the actual source of merge conflicts. And task locks are a mailbox
you poll, not a live channel: agents cannot say "I'm refactoring auth, stay
clear."

kazi coordinates on **resources, not identities**: an agent leases the set of
modules/files it will touch (its *blast radius*) before working. Disjoint leases
run free; overlapping ones serialize. Coordination happens over a live bus, so
sessions are mutually aware, not merely mutually exclusive.

---

## 3. Positioning: drive harnesses, never become one

kazi is **harness-agnostic** (ADR-0001). It shells out to whatever CLI coding
agent you have — Claude Code, Codex, future ones — through a thin, stateless
subprocess boundary (ADR-0008). This is the deliberate refusal to compete with
Claude Code / Codex / claw-code. As those harnesses improve, kazi improves for
free.

The boundary is generic: any CLI harness is described as a **profile** — how its
argv is assembled and how its output is parsed — and one shared adapter drives
every profile (ADR-0016). Adding a harness is declaring a profile, not writing a
new adapter; a fully custom harness can be configured without changing kazi.
Which harness runs is resolved by a fixed precedence — an explicit run-time
selection, then the goal's preference, then a configured default, then the
built-in default — so a goal can pin its harness while a single flag still
overrides it. `claude` is the default; doing nothing keeps today's behaviour.

What kazi owns is the layer none of them own: the **convergence + coordination +
truth** outer loop. Analogy: CI tells you what is broken but does not fix it;
agents fix things but do not know when to stop; kazi closes the loop.

---

## 4. Positioning, the other direction: a three-layer stack (ADR-0023)

Section 3 looks *downward* — kazi drives a harness. kazi is also good to drive
*from above*: an orchestrating agent should be able to run kazi programmatically
through the whole loop (plan -> author predicates -> converge -> validate ->
release). That puts kazi in the **middle of a three-layer stack** (ADR-0023):

```
  orchestrator agent  (claude code -- HIGH reasoning: plan/design, author predicates)
        |  drives kazi as a tool
        v
      kazi             (the controller -- objective predicates + convergence loop)
        |  drives the inner harness
        v
  cheap implementer    (claw -> local Qwen, opencode, codex, ... -- the keystrokes)
```

The point is **two-tier economics.** Spend expensive reasoning *once* on the part
that needs judgment — what "done" means: the plan and the acceptance predicates —
and spend cheap, local compute on the iterative grind of editing until those
predicates pass. kazi's objective termination is what makes the split safe: the
cheap implementer cannot declare victory on plausible-but-wrong work, because
truth lives in the controller (section 2, Gap 1), not in the model doing the
keystrokes. The expensive brain sets the bar; the cheap brain reaches for it;
kazi holds the bar still.

**This extends ADR-0001 without contradicting it.** ADR-0001 says kazi is the
*outer loop, not a harness* — kazi must never become the thing you type at. That
still holds: kazi does not type at the orchestrator, and the orchestrator is not
*inside* kazi. kazi is the outer loop **for the coding harness** below it and a
well-behaved inner **tool for the orchestrator** above it — friendly in both
directions at once. Being drivable as a tool is not the same as being a harness;
a harness runs the agent loop a human types into, while kazi exposes a structured
command surface an agent calls and parses. Both roles are the *same* kazi: the
controller that owns convergence, coordination, and objective truth.

Mechanically this is just symmetry. kazi already drives harnesses by emitting a
focused prompt and parsing structured output (ADR-0001, ADR-0016); being drivable
means kazi's own commands emit structured (`--json`) output an orchestrator parses
instead of screen-scraping prose — the same conformance bar kazi imposes on the
harnesses it drives, now applied to itself. The orchestrator owns the per-phase
model policy ("strong brain to author predicates, cheap brain to converge"); kazi
stays a pure tool and bakes none of that tiering in (ADR-0023). Predicate
authoring stays the single sanctioned `kazi plan` path (ADR-0011, ADR-0032)
regardless of which layer calls it, so the deterministic clarify floor and the
approve gate are never bypassed from above.

---

## 5. The goal contract (ADR-0002)

A **goal** is a declarative document:

- a set of **predicates**, each provided by a pluggable **predicate provider**
  that returns `{pass | fail, evidence}` — e.g. `unit`, `integration`, `api`,
  `browser`, `prod_5xx_rate == 0 over 30m`, `coverage >= baseline`;
- **guard predicates** that prevent gaming (test-count must not drop, coverage
  must not regress) — invariants the loop enforces, not goals to reach;
- a **budget** (tokens / wall-clock / iterations) — a hard ceiling;
- a **scope** (repo, paths) the agents may touch.

The goal's *acceptance* is the conjunction of all predicates. There is no
"the agent thinks it's done." Done is `∀ p ∈ predicates: eval(p) = true`.

### 5a. Importing intent, and detecting dead code (ADR-0021)

A goal's predicates do not have to be hand-typed. Correctness is framed as a
two-way containment between the **intended set I** (what should be true) and
the **actual surface A** (what the code exposes): `I \ A` is what the
convergence loop drives to done; `A \ I` is dead or undocumented code. `I` can
be imported, never invented by kazi itself:

- **Machine specs, deterministically** — `Kazi.Reconcile.OpenApiImporter` (one
  `http_probe` predicate per path/operation) and `Kazi.Reconcile.GherkinImporter`
  (one `custom_script` scaffold predicate per `.feature` Scenario, §10c/ADR-0050). Pure,
  hermetic — the same input always yields the same goal, and re-import upserts.
- **Prose, via the harness** — `Kazi.Reconcile.ProseImporter` drives the
  existing authoring/clarify path (§10, ADR-0011/0019) over an ADR or
  requirements doc to draft CANDIDATE predicates, always human-reviewed before
  acceptance. Fuzzy by nature; the deterministic paths above are the
  trustworthy backbone.

`A \ I` (dead code) is caught by a **surface-coverage meta-predicate**: a
scanner inventories a project's public surface (HTTP routes, exported symbols,
CLI commands) and asserts every element is owned by ≥1 intended predicate; an
unowned element FAILS, held true continuously by standing mode (§0), not a
one-shot report. `kazi init`/`adopt` (ADR-0013) stays the small CODE-side
bootstrap — it mirrors `A`, so it can express a regression guard but can never
state intent.

### 5b. Crystallizing empirically-discovered truth (ADR-0054, ADR-0051 decision 4)

§5a's three `I`-sources all require intent to be DECLARED — written down before
or alongside the code. A fourth source is empirical: exploring a *running*
system to discover `I` and `A \ I`. An earlier design (ADR-0051 decisions 1-3)
tried to close this with a bespoke, kazi-only "use-case manifest" JSON schema
and a one-shot harness prompt meant to replicate exhaustive live testing in a
single dispatch — corrected by ADR-0054: that repeated the exact mistake §5a's
own Gherkin choice had just avoided (inventing a format instead of adopting a
real one), and a single prompt cannot honestly promise the exhaustiveness a
dedicated audit tool provides.

The corrected design stays inside the SAME two mechanisms this doc already
describes. A product-level use case IS a Gherkin Scenario — a directory of
tagged `.feature` files (`@role:`/`@priority:`/`@interface:`, real Cucumber tag
syntax) at the product/capability scope, imported through the SAME
`GherkinImporter` §10c already uses (extended to read tags), via the SAME CLI
verb §10c describes — no new schema, no new importer module. Discovering those
Scenarios for an existing, undocumented codebase is not a one-shot prompt kazi
trusts blindly; it is a new `--discover` flag on `kazi init` (ADR-0013) writing <!-- verb-drift:allow: `--discover` is planned (E41/ADR-0054), not yet shipped -->
a starter goal whose predicate is a manifest-coverage check (every
surface-scanner-found element, T13.4, is referenced by ≥1 Scenario) — FALSE
until documented, driven to TRUE by ordinary `kazi apply`, converging over
iterations the same way any other goal does, with the harness receiving only
the grounded gap each iteration (ADR-0009). Wiring gaps stay on §5a's existing
surface-coverage meta-predicate, untouched. An opt-in prod-log correlation on
`browser`/`http_probe`/`custom_script` predicates (ADR-0051 decision 4,
retained) additionally flags a `:pass` verdict whose route is erroring live in
production — a discovered fact no importer alone would catch.

---

## 6. The convergence loop

```
observe   → evaluate every predicate, attach evidence, record the predicate VECTOR
diff      → the failing predicates ARE the work-list
dispatch  → drive an agent per work-item, given the failing-predicate evidence
            plus a deterministic blast-radius orientation pack (ADR-0009/0010) —
            map memory, never conversation memory — inside a leased blast radius
re-observe→ re-evaluate; compare new vector to previous
decide    → converged (all true) | progressing | stuck | regressed | over-budget
```

The loop's hard parts — and therefore the product — are the failure modes:

- **Regression / oscillation.** A fix for predicate A breaks predicate B. The
  controller tracks the full predicate *vector* across iterations; a predicate
  that was green and went red is a regression, flagged against the change that
  caused it, not counted as progress.
- **Flaky predicates.** A flaky test would poison the loop into infinite "work."
  Predicate providers must support re-run / quarantine so a nondeterministic fail
  is not treated as real work. A quarantined predicate stays out of the
  work-list, but (#820) is not abandoned forever: it is still polled through the
  real provider, and a sustained run of real passes rehabilitates it back onto
  the convergence bar.
- **Gaming.** Guard predicates (test-count, coverage ratchet) block the "delete
  the failing test" shortcut.
- **No-progress / runaway.** A budget ceiling plus a stuck detector (N
  iterations, same failing set) that **escalates to a human** rather than burning
  money. When the ONLY thing left unsatisfied is quarantined predicates and there
  is nothing to dispatch (#820), the loop does not idle at the reobserve interval
  to the budget ceiling either — it stops honestly `:stuck`, naming the
  quarantined ids, after a small bounded number of no-work ticks; any other
  no-work wait (e.g. a live predicate still pending) backs off its poll interval
  instead of a sub-second busy-spin.
- **Persistent live errors (ADR-0058, UC-064).** A live predicate (`http_probe`
  and friends) that errors on EVERY observation is invisible to the ordinary
  stuck check above — it is reduced away deliberately, since step 5 legitimately
  polls a live predicate rather than dispatching an agent to "fix" it. Left
  alone, a config problem knowable on the first observation (an `http_probe`
  missing its required `url`) would instead spin every remaining iteration to
  `:over_budget`, mislabeling a wedge as budget exhaustion. Each `:error` reason
  carries a permanence class — `:permanent` (a config/wiring problem that will
  never clear, e.g. `:missing_url`, `:no_provider`) or `:transient` (may clear,
  e.g. a timeout). A persistent, same-id, all-`:permanent` stretch across the
  stuck window stops the loop honestly `:stuck`, naming the predicate and its
  last-observed reason; a persistent `:transient` stretch is unaffected and
  keeps polling at the existing backed-off interval — a probe that is
  legitimately still warming up sees no behavior change.

`/qualify` (the original pain) is simply the goal
`{unit, integration, api, browser, prod_logs}` run through this loop — but as a
deterministic controller, not a checklist an LLM may skip.

---

## 7. Coordination model (ADR-0006)

- **Resource leases.** An agent leases its blast radius before editing, with
  revision-based CAS (atomic) and per-key TTL (a crashed agent's lease
  auto-expires -- no manual prune). On a single machine the lease is in-memory and
  NATS-free; multi-machine backs it with NATS JetStream KV. The lease behaviour is
  the same either way; only the substrate changes (ADR-0027).
- **Graph-aware partitioning.** A task's blast radius is computed from
  `code-review-graph` (already deployed across the user's repos). kazi hands
  parallel agents *non-overlapping* blast radii by construction → conflict-free
  parallelism, not just collision detection.
- **Live channel.** Presence heartbeats and intent announcements flow over
  JetStream subjects, so sessions are aware of each other.
- **Merge convergence.** Parallel fixers work in isolated git worktrees;
  integration is itself a reconcile sub-step (the merge-safety protocol),
  shrunk — not eliminated — by disjoint leases.

---

## 8. Native parallel scheduler (ADR-0027)

Coordination (section 7) is the substrate -- leases and graph-aware blast-radius
partitioning. The scheduler is what consumes that substrate to run many goals at
once, and it lives INSIDE kazi. kazi does not assume an external launcher spawns
the N goals; kazi owns the parallelization itself (ADR-0027).

Given a goal-set, `kazi apply` parallelizes by reconciling, not by forking a
swarm:

```
partition  -> split the goal-set by blast radius (the code-review-graph /
              repo-map) into DISJOINT partitions -- conflict-free parallelism by
              construction, not reactive collision detection. A single goal, or
              no graph, degenerates to one partition (serial, today's behaviour).
lease      -> take a PartitionLease for the life of each partition's run. Residual
              overlap (a partition's edits expand its radius) serializes on the
              lease.
spawn      -> start one supervised reconciler per partition under a
              DynamicSupervisor. Each reconciler is the SAME per-goal serial
              convergence loop (section 6) -- parallelism is ACROSS partitions,
              the inner loop is unchanged.
converge   -> a coordinator process tracks every partition's terminal state and
              reports COLLECTIVE status: all converged | any stuck | over budget.
merge      -> each fixer works in its own git worktree; integration is itself a
              reconcile sub-step (merge convergence). Disjoint blast radii make
              conflicts rare; a residual conflict re-dispatches the affected
              partition.
```

Single-node parallelism is **NATS-free**: an in-memory lease
(`Kazi.Coordination.Lease.Memory`) plus the `DynamicSupervisor` coordinate N
reconcilers in one BEAM. JetStream (ADR-0004) is reserved for the multi-machine
case and is selected by config, not required to parallelize on one machine.

Parallelism is OPT-IN scale (`kazi apply --parallel [N]`, or automatic from a
multi-partition goal-set); single-goal stays the simple serial on-ramp. This is
the outer-loop role (ADR-0001) taken to its conclusion: kazi still drives
harnesses and is not one -- it now orchestrates several harness dispatches under
supervision, each converging an objective partition. It is not a "swarm of fake
agents" (section 10): every concurrent unit is a real supervised reconciler over
a leased blast radius.

### 8a. Predicate-graph waves: dependency-aware ordering (ADR-0028)

Blast-radius partitioning gives SPATIAL parallelism (disjoint edits run free). It
says nothing about SEMANTIC order: when group B logically depends on group A's
output (the streaming predicates need the result-contract predicates true first),
two spatially-disjoint groups may still need to run in order. ADR-0028 adds that
missing axis -- **predicate-graph waves**.

This is kazi's codification of the wave pattern an external orchestrator authors
by hand: a planning step declares each task's `deps:`, and an apply step executes
the result as ordered *waves* (parallel within a wave, a barrier between waves).
kazi keeps the authored dependencies but replaces the hand-grouped, statically
barriered waves with a schedule it COMPUTES: the predicate group taxonomy
(`[[group]]`, ADR-0020) plus `needs` edges form a dependency graph over the
goal's predicates, and kazi derives the wave order from that graph -- hence
*predicate-graph waves*. The grouping foundation is ADR-0020; the scheduler that
runs the frontier is ADR-0027 (section 8); this section is the ordering layer
ADR-0028 adds on top.

- **Declare `needs` edges.** A predicate group (the `[[group]]` taxonomy,
  ADR-0020) carries an optional `needs = ["group-id", ...]` -- a
  "must-converge-before" edge set, distinct from `parent` (which stays
  budget-rollup only). Edges are validated at load: every id must exist, no
  self-edge, no cycle. Absent edges mean fully parallel (the section 8 behaviour).
- **Compute the ready set.** From the `needs` edges plus each group's current
  convergence state, kazi derives the groups whose every dependency has
  OBJECTIVELY converged (predicates true with evidence -- not "an agent said
  done"). This is pure and deterministic.
- **Topological + spatial, pipelined (no barrier).** The scheduler dispatches only
  ready groups, partitions that ready set by blast radius, and runs the partitions
  concurrently. A group becomes ready the MOMENT its specific deps converge -- not
  when a whole wave finishes -- so there is no slowest-in-wave tax.
- **Objective re-gating.** Readiness is defined by observed convergence, so a dep
  that later regresses (the regression guard fires) re-gates its dependents: they
  return to not-ready and re-converge. The DAG is re-evaluated against observed
  state each cycle -- the reconciler property, not a one-shot plan.
- **Blocked-dependency escalation.** If a dep group goes stuck or over budget, its
  dependents can never become ready; the scheduler escalates the affected sub-DAG
  and NAMES the blocking dep in the collective status, rather than hanging
  silently.

**Express the deps in the goal-file.** You author `needs` on the `[[group]]`
taxonomy; a predicate joins a group with `group = "<id>"`. Edges name the groups
that must converge BEFORE this one:

```toml
[[group]]
id   = "result-contract"
name = "Result Contract"

[[group]]
id    = "streaming"
name  = "Streaming"
needs = ["result-contract"]   # don't start streaming until the contract converges

[[predicate]]
id       = "contract-shape"
provider = "test_runner"
group    = "result-contract"

[[predicate]]
id       = "stream-emits-tokens"
provider = "test_runner"
group    = "streaming"
```

**Run it the same way as any goal** -- `kazi apply <goal-file> --parallel`. When
the goal's groups declare `needs`, the scheduler routes the run through the
dependency-aware path automatically; with NO `needs`, it stays the fully-parallel
scheduler of section 8 (back-compatible). Under `--json`, the collective result
names any blocked sub-DAG and its blocking dep, so a stuck dependency is reported,
not silently hung.

The irreducible input is the dependency edges: kazi computes everything
downstream of them, but it cannot DERIVE logical precedence from code (only
spatial disjointness, from the blast-radius graph). Authoring the `needs` edges is
human/LLM judgment and a real burden -- a human (or the planning agent) writes
them once, and an over-declared edge needlessly re-serializes work. What kazi
guarantees is everything AFTER that declaration: it computes the ready set, runs
each frontier with spatial parallelism, re-gates on objective convergence, and
escalates blocked sub-DAGs -- it does not infer the order itself.

### 8b. Interop: kazi under an external pool orchestrator (ADR-0026)

Section 8 is kazi OWNING parallelism (the native scheduler). The mirror case is
kazi as a good citizen UNDERNEATH a parallel orchestrator someone already runs --
the operator's `/loop /apply --pool` (many Claude Code sessions, each `/claim`-ing
a plan task and rebase-merging a PR), a CI matrix, any swarm. That hand-rolled
workflow is a re-implementation of kazi's own problem statement, and it carries
three documented failure modes: **session-asserted done** (each session decides
its own task is finished -- the Gap-1 failure, which has produced false "merged"
reports), **wave stalls** (a session dies on an auth/push/test failure with no
self-recovery), and **coarse coordination** (`/claim` locks a task *id*, not the
code it touches, so two tasks editing the same function both merge clean and break
behaviour -- a silent logical conflict). kazi already ships the primitive for each.

So ADR-0026 slots kazi UNDER each pool session rather than replacing the pool:

- **Two-tier coordination, composed not replaced.** `/claim` stays the OUTER lock
  (which session takes which task); kazi's blast-radius lease (section 7) becomes
  the INNER lock (what code the run may touch). Claim = task selection, lease =
  blast radius -- the same `/claim` ↔ lease boundary the pool guides spell out.
- **The authoring bridge is `kazi plan` caller-drafts (ADR-0023).** A session turns
  its task's `acc:` line into predicates through the single sanctioned authoring
  path -- no parallel mechanism -- and `kazi apply` is then the objective-done gate
  that can BLOCK a merge the session would otherwise have asserted done.

This does NOT contradict section 8 or ADR-0001. ADR-0027's native scheduler is the
PRIMARY parallel story (kazi owns the swarm); ADR-0026 is RETAINED only as the
interop story for when an external orchestrator owns scheduling and kazi supplies
objective-done + finer coordination beneath it. Both are the same kazi -- the
controller that owns convergence and truth -- exposed at different layers. The
operator-facing recipes for this live in the pool guides (the `acc:`→predicates
bridge, the per-task drive recipe, the verification gate, the blast-radius lease,
and the claim↔lease deadlock-safety boundary).

---

## 9. Architecture & data layers (ADR-0003, ADR-0004, ADR-0005)

**Runtime:** Elixir / OTP. Each active goal/partition is a supervised reconciler
(`GenStateMachine`); a coordinator supervises the population of reconcilers (the
native scheduler, section 8), with supervisors per dispatched agent under
restart/escalation strategies and watchers for leases and predicates. Phoenix
LiveView for the live console. The domain *is* "a supervised population of
fallible concurrent processes," which is the BEAM's purpose.

**Four stores, each authoritative for exactly one thing — so none ever has to
grow into another's role:**

```
Git              source of truth for CODE (branches, worktrees, PRs)
NATS JetStream   source of truth for COORDINATION
                   KV leases : blast-radius leases, CAS by revision, per-key TTL
                   KV goals  : declared desired state (predicate specs)
                   stream    : kazi.events — append-only evidence/iteration log
                   subjects  : presence.*, intent.* — ephemeral live chatter
BEAM / ETS       LIVE working set of active reconcilers (predicate vector,
                 in-flight agents, lease cache); drives LiveView; rehydrated
                 from JetStream on restart
SQLite (WAL)     local materialized READ-MODEL projected from kazi.events:
                 predicate/lease history, convergence analytics; rebuildable,
                 never authoritative
```

This is CQRS: JetStream is the only coordination truth, SQLite is a disposable
projection of it, ETS is the live cache, Git owns code. The design does not
change from one machine to many — single-machine is the same substrates with the
cluster degenerate to one node. Nothing gets swapped later (the explicit
requirement that drove ADR-0004/0005).

Memory is a fourth read of these same stores, not a fifth store (ADR-0060): see
[docs/memory.md](memory.md) for the four-layer map and how each layer is
projected from data this section already describes.

---

## 10. The agent drives kazi (ADR-0024, ADR-0031)

The human sets *direction*, not keystrokes. The human's interface is the
orchestrating agent (Claude Code): they say "build X with kazi" and the agent
drives `kazi plan` -> `approve` -> `kazi apply`, then pings back on `converged`,
`stuck`, or `needs-decision`. Status routing lives outside kazi's context window
so the agent stays focused on implementation. The LiveView dashboard is for
inspection (goal board, agent presence, lease map, convergence history), not for
driving.

**The agent is the human's mobile interface.** Because the orchestrating agent is
the thing the human talks to, the agent app (web/mobile) IS the remote control:
the human declares and approves goals from their phone by chatting with the agent,
and the agent's own push notifications report terminal states from the run it is
already driving. kazi therefore ships **no** separate chat or notification
surface of its own (ADR-0029); the headless-autonomous case, if it ever
activates, is served by a future generic webhook, not a bespoke bridge.

**kazi is self-teaching, so the agent already knows how to drive it** (ADR-0024).
kazi describes itself in machine-readable form (`kazi help --json`,
`kazi schema`) and ships the integration glue for the dominant harness: an opt-in
Claude Code skill (`kazi install-skill`), a harness-neutral `AGENTS.md`, and an
MCP server (`mix kazi.mcp`) exposing the same commands as self-describing tools.
The on-ramp is "install kazi -> the agent can drive it,"
not "read the docs first."

**One front door: the router skill** (ADR-0031). The Claude Code skill is a
ROUTER whose sub-skills are the operator's human verbs, each driving a real kazi
command:

- `kazi plan <idea>` -- author or refine the goal-set (predicates, `[[groups]]`,
  `needs` edges) through the single sanctioned authoring path (caller-drafts,
  ADR-0023), with the deterministic clarify floor and the approve gate intact.
- `kazi apply [--parallel] [--standing]` -- converge the goal-set via the native
  scheduler and dependency-aware waves (sections 8, 8a). This subsumes the
  operator's old loop/apply/qualify glue for code goals: the reconcile loop is
  internal, `--standing` re-converges on drift, and "launch-ready" is just the
  predicate vector being objectively satisfied (including a live prod probe), not
  a heuristic verdict.
- `kazi status` -- convergence state (the `--json` read); the LiveView console is
  the live dashboard for inspection (goal board, presence, lease map).
- `kazi init <repo>` (the router's `adopt` verb) -- reverse-engineer a starter goal-set
  from an existing repo.

Verb consistency end to end (ADR-0032): the skill verb, the thing the human types
at the agent, and the CLI command read the same. `kazi plan` authors intent;
`kazi apply` converges it -- mirroring `/plan` and `/apply`. (`run`/`propose`
were removed at v1.0.0; use `kazi apply`/`kazi plan` -- see docs/deprecations.md.)
This keeps kazi an outer-loop tool the agent calls (ADR-0001), not a
harness the human types into directly.

### 10a. The docs are themselves a kazi goal (ADR-0036)

The plan (`docs/plan.md`) IS kazi's `goal.toml` -- the executable spec the apply
loop reconciles against -- and the stable docs (`concept.md`, `lore.md`, ADRs) are
the orientation every dispatch carries. Both rot: completed epics accumulate in the
live plan (inflating per-dispatch context, a direct token cost) and the prose
drifts from a moving codebase (the stale-context failure objective predicates exist
to prevent). The flagship dogfood (ADR-0036) is to apply kazi's own thesis to its
docs -- make trim and freshness a kazi-reconciled STANDING goal rather than another
LLM-driven, manually-triggered, unenforced cleanup. The logic lives in the
skill + CI predicate layer; kazi only DRIVES it, so the core stays an
unopinionated controller (the ADR-0023/0033/0035 line):

- **Layer 1 -- deterministic structural trim (lossless).** A script (not an LLM)
  archives an epic out of the live plan ONLY when it is 100% `[x]` AND release-tag
  covered, moving the block verbatim to a git-tracked archive and leaving a
  one-line pointer. Idempotent and reversible.
- **Layer 2 -- gated knowledge extraction (LLM, propose-then-confirm).** AFTER
  Layer 1 has preserved the raw block, the LLM lifts only durable nuggets to the
  right tier (invariant→`lore.md`, finding→`devlog.md`, decision→`adr/`,
  architecture→`concept.md`). Because the archive already holds everything, a
  routing mistake never LOSES knowledge.
- **Layer 3 -- freshness as predicates (the enforcement).** A machine-checkable
  doc-freshness set runs in CI and fails the build on drift: every shipped command
  appears in README + `help --json`, no doc names a symbol absent from the code,
  every referenced ADR exists, and no `[x]` task older than the last release
  remains in the live plan. These are the same predicate kinds (a `ratchet` on the
  documented-command %, a count that ratchets to 0) kazi gates any goal with.

This is the reconciler property turned on kazi itself: the docs are the desired
state, the freshness checks are the predicates, and kazi keeps actual state
matching. The runnable set is documented in `docs/doc-freshness.md`; the trim tool
is `.github/scripts/trim_plan.py`.

### 10b. Where these docs live (presentation decision)

**Decided: the repository is the single source of truth for documentation; the
website does NOT host a rendered `/docs` tree (no docs-site generator, no second
copy to keep in sync).** The canonical docs are the Markdown under `docs/` in this
repo, read on GitHub. The website (kazi.sire.run) is a marketing + on-ramp surface
-- the hero spine, the quickstart pointer, and links INTO the repo docs -- not a
documentation mirror. Rationale: a rendered docs site is a second copy that drifts
from the code it documents (the exact Layer-3 failure above), and the audience for
deep docs is an agent or a contributor already in the repo, not a web visitor.
README↔site coherence is enforced as a freshness predicate (T9.9); full guides stay
single-sourced in `docs/`. If a rendered docs site is ever added, it must render
FROM `docs/` (one source), never duplicate it.

### 10c. Behavior specs: the Gherkin tier (ADR-0050)

The five tiers above answer WHY (`docs/adr/`), WHAT THE SYSTEM IS (`concept.md`),
WHAT'S LEFT (`docs/plan.md`), WHAT HAPPENED (`devlog.md`), and WHAT MUST NEVER
HAPPEN (`lore.md`) -- but nothing answered WHAT BEHAVIOR IS BEING BUILT, reviewably,
before code. A WBS one-liner plus a hand-authored predicate was the entire "spec"
for a task.

**`docs/specs/`** closes this: one `<slug>.feature` file per non-trivial task,
written in the Gherkin subset `Kazi.Reconcile.GherkinImporter` already parses
(Feature/Scenario/Given/When/Then, ADR-0021/T13.2), optionally paired with a short
`<slug>.md` proposal note. A plan task may point at its spec via an optional
`spec:` WBS field. The CLI verb `kazi spec import <feature-file>... --into
<goal-file>` (ADR-0050/T40.2) upserts the spec's Scenarios as `[[predicate]]`
entries in the goal -- **predicates are DERIVED from a reviewed spec, not
hand-typed** -- and when the epic archives (10a, Layer 1), its referenced specs
move to `docs/specs/archive/` with it. Re-importing an edited spec is an upsert
(each predicate's id is derived from Feature + Scenario), so a hand-added live
predicate in the goal-file survives untouched. See `docs/specs/README.md`.

Call this tier "behavior specs" in prose: kazi already overloads bare "spec" three
other ways (Elixir `@spec`, "goal spec" as a synonym for `goal.toml` in this very
section, and ADR-0021's external-machine-spec import sense). `docs/specs/` is
optional per task, not mandatory -- it exists for behavior worth reviewing before
code, not every WBS line.

**Two scopes, one tier (T41.2, ADR-0054).** The same `docs/specs/` tier serves a
second scope, and it is deliberately NOT a new tier: `docs/specs/product/<domain>.feature`
is the durable **use-case catalog** -- one `Feature:` per product capability, one
`Scenario:` per use case, tagged with the T41.1 vocabulary (`@role:`, `@priority:`,
`@interface:`). Same Gherkin subset, same `GherkinImporter`, same `kazi spec
import` verb, no new flag and no new schema; only the path and the reading differ.
A **task spec** (above) is scaffolding for work in flight and archives with its
epic; a **product spec** answers "what can this product do, for whom, and how is
it exercised?" and outlives any one task. The tag vocabulary is what makes the
catalog queryable -- declare a domain's role/priority/interface once on the
`Feature:`, let each `Scenario:` inherit and override only where it differs.
Worked example: `docs/specs/product/convergence.feature`. See
`docs/specs/README.md` ("Two scopes").

---

## 11. What kazi is NOT

- Not a coding agent, terminal, or IDE. It drives them.
- Not a "swarm" of fake agents. Concurrency is real OS processes under leases.
- Not a memory/vector product. The core loop is deterministic; trajectory
  learning ("what fixed this predicate failure last time") is a *later, pluggable*
  memory adapter — never the foundation.

---

## 12. Build order (a vertical slice of the final design, not a different one)

Each milestone uses the *final* substrates at n=1; nothing is throwaway. The
walking skeleton spans idea → production from Slice 0: every lifecycle phase gets
its thinnest version on day one (integrate + deploy + verify-live included), and
later slices *deepen* phases rather than add missing ones (ADR-0007).

- **MVP-0 (Slice 0)** — one goal spanning code + live predicates (`tests green`
  AND a live prod probe), a test-runner provider, an http_probe provider, a
  `claude -p` adapter, the convergence loop with non-agent **actions** (integrate:
  branch/PR/merge; deploy: ship the artifact), objective termination, evidence in
  SQLite. Single node. Proves a thin idea → production reconcile on a tiny
  deployable fixture.
- **MVP-1 (Slice 1)** — regression + flake + budget/stuck handling; add the
  prod-log predicate and the coverage guard → full `/qualify` as a controller.
- **MVP-2 (Slice 2)** — creation mode (failing acceptance predicates + browser
  provider + vacuous-goal guard); kazi builds features, not only repairs.
- **MVP-3 (Slice 3+)** — deepen: JetStream leases + presence, graph-aware
  partitioning, richer deploy (multi-env/rollback), standing reconcilers,
  idea→predicate front-end, LiveView dashboard.

Dogfood on real repos through MVP-2 before any world-facing claim; from creation
mode onward, kazi builds kazi.

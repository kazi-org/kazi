# kazi — Concept & Architecture

This is the canonical source of truth for what kazi is, why it exists, and how
it is built. Decisions are frozen as numbered ADRs in [`adr/`](adr/); this
document is the narrative that ties them together. Update it when a decision
changes (and write/super­sede the ADR).

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

kazi is **harness-agnostic** (ADR-0001). It shells out to whatever coding agent
you have — `claude -p`, Codex, future ones — through a thin adapter. This is the
deliberate refusal to compete with Claude Code / Codex / claw-code. As those
harnesses improve, kazi improves for free.

What kazi owns is the layer none of them own: the **convergence + coordination +
truth** outer loop. Analogy: CI tells you what is broken but does not fix it;
agents fix things but do not know when to stop; kazi closes the loop.

---

## 4. The goal contract (ADR-0002)

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

---

## 5. The convergence loop

```
observe   → evaluate every predicate, attach evidence, record the predicate VECTOR
diff      → the failing predicates ARE the work-list
dispatch  → drive an agent per work-item, given ONLY the failing-predicate evidence
            as context, inside a leased blast radius
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
  is not treated as real work.
- **Gaming.** Guard predicates (test-count, coverage ratchet) block the "delete
  the failing test" shortcut.
- **No-progress / runaway.** A budget ceiling plus a stuck detector (N
  iterations, same failing set) that **escalates to a human** rather than burning
  money.

`/qualify` (the original pain) is simply the goal
`{unit, integration, api, browser, prod_logs}` run through this loop — but as a
deterministic controller, not a checklist an LLM may skip.

---

## 6. Coordination model (ADR-0006)

- **Resource leases.** An agent leases its blast radius before editing. Leases
  live in NATS JetStream KV with revision-based CAS (atomic) and per-key TTL (a
  crashed agent's lease auto-expires — no manual prune).
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

## 7. Architecture & data layers (ADR-0003, ADR-0004, ADR-0005)

**Runtime:** Elixir / OTP. One supervised process per active goal
(`GenStateMachine`), supervisors per dispatched agent with restart/escalation
strategies, watchers for leases and predicates. Phoenix LiveView for the live
console. The domain *is* "a supervised population of fallible concurrent
processes," which is the BEAM's purpose.

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

---

## 8. Human interface — off the context window

The human sets *direction*, not keystrokes. A goal can be declared from a phone
(Telegram / Discord); kazi pings back on `converged`, `stuck`, or
`needs-decision`. Status routing lives outside the agent's context window so the
agent stays focused on implementation. The LiveView dashboard is for inspection
(goal board, agent presence, lease map, convergence history), not for driving.

---

## 9. What kazi is NOT

- Not a coding agent, terminal, or IDE. It drives them.
- Not a "swarm" of fake agents. Concurrency is real OS processes under leases.
- Not a memory/vector product. The core loop is deterministic; trajectory
  learning ("what fixed this predicate failure last time") is a *later, pluggable*
  memory adapter — never the foundation.

---

## 10. Build order (a vertical slice of the final design, not a different one)

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
  idea→predicate front-end, LiveView dashboard, Telegram goal-in / ping-out.

Dogfood on real repos through MVP-2 before any world-facing claim; from creation
mode onward, kazi builds kazi.

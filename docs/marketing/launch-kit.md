# kazi launch kit — ready-to-paste copy

The actual words for launch day. Fills in the drafts referenced by
[launch-plan.md](launch-plan.md) Phases 1–2. Every command here is verified
against the shipped surface (`apply`, `plan`, `status`, `approve`, `reject`,
`list-proposed`, `init`, `help`, `version`); the removed verbs `run`/`propose`
appear nowhere. Positioning strings quote `site/src/canonical.mjs` verbatim.
Editorial bar: [ADR-0048](../adr/0048-adoption-blog-series-editorial-stance.md) —
pain first, no hype words, no unshipped capability as working, honest
limitations stated.

> **Before posting:** re-read each piece in your own voice and personalize the
> backstory lines marked `[…]`. The copy is written to sound like you, but the
> specific war story should be a real one of yours.

---

## 1. Show HN

### Title (pick one — A recommended)

- **A.** `Show HN: Kazi – drives your coding agent until tests, probes, and budgets say done`
- **B.** `Show HN: Kazi – an objective "done" gate for coding agents (open source, Elixir/OTP)`
- **C.** `Show HN: Kazi – a reconciliation loop that drives coding agents to verified "done"`

Rules: link the **GitHub repo**, not the site. Post Tue/Wed ~8–9am US Eastern.
Never solicit upvotes.

### First comment (post immediately after submitting)

> Hi HN — I'm David. I've been building with coding agents daily, and I kept
> hitting the same wall: the agent says "done," the diff looks clean, I move
> on — and days later it's subtly wrong. A test that got deleted instead of
> fixed. An endpoint that returns 200 locally but was never actually deployed.
> The bottleneck was never the model's coding ability. It was that **"done"
> was the agent's own opinion**, with nothing objective checking it.
>
> Kazi is my attempt to fix that. You declare a goal as a set of
> machine-checkable predicates in a small TOML file — "the unit tests pass,"
> "GET /healthz returns 200 on the deployed URL," "coverage doesn't drop" —
> and kazi drives your coding agent (Claude Code by default; also Codex,
> opencode, Gemini CLI) in a loop: observe which predicates are failing,
> dispatch the agent to fix them, integrate, deploy, re-check. It only reports
> success when **every** predicate is objectively true with stored evidence —
> otherwise it stops and tells you it's `stuck` or `over_budget`. Think
> Kubernetes-style reconciliation, but the resource is your codebase and the
> actuator is a coding agent. Kazi drives the agent; it isn't one.
>
> What I think makes it different from a bare `while` loop, a Ralph loop, or
> the agents' own built-in "loop until done":
>
> - **The gate is deterministic predicates, not an LLM judging itself.** Truth
>   lives in the controller, not the model doing the keystrokes.
> - **The graders are tamper-proof.** A goal can mark its checker scripts and
>   config `read_only_paths`, so the agent can't "pass" by editing the test or
>   the grader — the reward-hacking shortcut is designed out.
> - **Hard budgets + honest terminal states.** It can't loop forever or burn
>   tokens silently; it converges, gets stuck, or hits the budget ceiling, and
>   says which.
> - **The goal is a versioned artifact** (`goal.toml`) you can review, diff,
>   and re-run — not a prose prompt.
> - **It's harness-agnostic.** As Claude Code / Codex get better, kazi gets
>   better for free. It's the layer above whichever agent you already use.
> - **Predicates can probe the deployed system** — a live HTTP/browser check,
>   not just green-on-my-laptop.
>
> Honest limitations: kazi does **not** decide *what* to build — that's your
> judgment; it only drives toward an outcome you declare. It needs a coding
> agent already installed on your PATH (it shells out to one). Predicate
> quality matters — vague predicates give vague results, same as vague specs.
> And the "spend frontier reasoning once, grind on a cheap model the
> predicates keep honest" cost story is the *intended* economics; I state the
> shape of the saving, not a measured dollar figure, until the benchmark
> lands.
>
> It's built in Elixir/OTP because the problem *is* "supervise a population of
> fallible concurrent processes" — one supervised reconciler per goal, leases
> so parallel agents don't edit the same files, a SQLite read-model for
> history. Slices 0–3 are implemented with ~700 hermetic tests, and kazi now
> builds kazi (it drives Claude Code to develop itself; the real recorded run
> and reproducible converged cases are on the site).
>
> Install is `brew install kazi-org/tap/kazi`, Apache-2.0. I'd genuinely love
> feedback — especially on failure modes you hit driving agents in a loop, and
> whether the predicate model maps to how you'd want to define "done."

---

## 2. X / Bluesky thread

Pain first, product last. No "10x", no "game-changer". Attach the ~30s
convergence clip to post 1. Cross-post verbatim to Bluesky.

```
1/ Your coding agent says "done." The diff looks clean. You ship it.
   Days later it's subtly wrong — a deleted test, an endpoint that was
   never actually deployed.

   The bottleneck was never the model. It was that "done" was the
   agent's opinion, with nothing objective checking it. 🧵

2/ So I built kazi: you declare "done" as machine-checkable predicates
   ("tests pass", "the DEPLOYED /healthz returns 200", "coverage doesn't
   drop"), and it drives your coding agent in a loop until every one is
   objectively true — or it stops and says stuck / over_budget.

3/ Think Kubernetes reconciliation, but the resource is your codebase and
   the actuator is a coding agent. Observe what's failing → dispatch the
   agent → integrate → deploy → re-check. Truth lives in the controller,
   not the model doing the keystrokes.

4/ Why it's not just a while-loop:
   • deterministic predicates, not an LLM grading itself
   • tamper-proof graders (the agent can't edit the test to "pass")
   • hard budgets — it can't burn tokens forever
   • the goal is a versioned goal.toml you can review & diff

5/ It's harness-agnostic — drives Claude Code, Codex, opencode, Gemini
   CLI. As they get better, kazi gets better for free. It's the layer
   ABOVE the agent you already use, not a competitor to it.

6/ Honest about the edges: kazi doesn't decide WHAT to build (that's you),
   it needs an agent on your PATH, and good predicates matter as much as
   good specs. It converges the goals you can define; it can't define them
   for you.

7/ Open source (Apache-2.0), Elixir/OTP, and it builds itself now —
   kazi drives Claude Code to develop kazi.

   brew install kazi-org/tap/kazi
   github.com/kazi-org/kazi
```

---

## 3. ElixirForum — "Your Libraries & Projects"

Lead with the architecture story; this audience rewards genuine OTP design.
Humble, technical, invites critique.

> **Title:** kazi — a reconciliation controller for coding-agent goals (Elixir/OTP)
>
> Hi all — I want to share something I've been building in Elixir that leans
> hard on OTP, and get the forum's read on the design.
>
> **The problem.** Coding agents (Claude Code, Codex, …) stop when they
> *believe* they're done — there's no objective gate, so they routinely report
> success on work that's merely plausible. I wanted a controller *above* the
> agent that only declares a goal met when a set of machine-checkable
> predicates are objectively true, with evidence — and otherwise honestly
> reports `stuck` or `over_budget`.
>
> **Why Elixir/OTP.** The domain turned out to be almost purely "supervise a
> population of fallible concurrent processes," which is the BEAM's home turf:
>
> - Each active goal is a supervised reconciler (`GenStateMachine`) running an
>   observe → dispatch → integrate → deploy → re-observe loop; a coordinator
>   supervises the population when you parallelize.
> - Parallel agents coordinate on **resources, not identities** — a run leases
>   the blast radius (the files/modules it will touch) before editing, with
>   revision-CAS + per-key TTL, so a crashed agent's lease auto-expires.
>   Single-node it's an in-memory lease (NATS-free); multi-node backs it with
>   JetStream KV — same behavior, only the substrate changes.
> - Data split by authority: Git owns code, JetStream owns coordination, ETS
>   holds live state, and SQLite (WAL) is a disposable read-model projected
>   from the event log. Straight CQRS; nothing gets swapped as you scale from
>   one machine to many.
> - Isolated git worktrees per parallel fixer; integration is itself a
>   reconcile sub-step.
>
> It's a single self-contained binary via Burrito (no Erlang prereq to
> install), Apache-2.0. Slices 0–3 are implemented with ~700 hermetic ExUnit
> tests, and it now dogfoods itself — kazi drives a coding agent to develop
> kazi.
>
> ```sh
> brew install kazi-org/tap/kazi
> ```
>
> Repo: https://github.com/kazi-org/kazi — concept doc, ADRs, and reproducible
> converged runs are all in there. I'd love feedback on the coordination model
> especially (leases-on-blast-radius vs task locks), and on anything that
> reads as un-idiomatic OTP. Happy to answer anything.

Also post a one-line pointer to https://elixirstatus.com (feeds ElixirWeekly)
and share in the Elixir Slack/Discord `#announcements`.

---

## 4. r/ClaudeAI showcase (day after Show HN)

Re-read the subreddit rules first. Attach the clip.

> **Title:** I built an open-source controller that drives Claude Code until
> machine-checkable predicates pass — so "done" isn't the agent's opinion
>
> Body: I kept hitting the wall where Claude Code says "done" and it's subtly
> wrong — a deleted test, an endpoint that returns 200 locally but was never
> deployed. kazi lets you declare "done" as predicates (tests pass, the
> deployed endpoint is live, coverage holds) and drives Claude Code in a loop
> until they're objectively true, or it stops and tells you it's stuck /
> over budget. The gate is deterministic checks, not the model grading itself,
> and the graders are tamper-proof so it can't "pass" by editing the test.
> Harness-agnostic (also Codex/opencode), Apache-2.0, Elixir/OTP.
> `brew install kazi-org/tap/kazi` · github.com/kazi-org/kazi. Feedback very
> welcome, especially failure modes you've hit looping agents.

---

## Pre-post checklist (every piece)

- [ ] No `kazi run` / `kazi propose` anywhere (removed at v1.0.0).
- [ ] No hype words ("10x", "game-changer", "revolutionary", "AI-powered").
- [ ] No cost/speed number stated as *measured* that isn't reproducible.
- [ ] Every command copy-pastes and works on a clean machine.
- [ ] The limitations paragraph is intact — it's what earns HN's trust.
- [ ] Links go to the repo (Show HN) / carry the launch UTM where syndicated.

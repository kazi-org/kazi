# kazi Growth Strategy — Executive Summary

*Full detail: `docs/marketing/strategy.md`, `launch-plan.md`, `operator-tasks.md`*

## The situation

The launch machine is **built but never fired**. README, website, the real
recorded hero cast, the `/proof` convergence gallery, and the full 12-part
blog series are all live. The only open item is the launch itself — an
execution gap, not a product or content gap.

**The moment is unusually good.** 2026's discourse has converged on kazi's
exact thesis: agent "loop engineering" is everywhere, and its loudest
critique is *no objective verification* — loops ship slop with confidence,
burn tokens forever, and stop on the model's own opinion of "done." Published
studies of agents gaming benchmarks (reward hacking) made this a front-page
story. Spec-driven tools (spec-kit, Kiro, Tessl) won the *intent* layer but
ship no enforcement — the spec is prose an agent reads, not predicates a
controller checks. Several pure-orchestration "swarm manager" tools have
already died, which is evidence *for* the thesis that verification is the
missing layer.

**The open gap: nobody owns the referee.** Everyone is building the loop, the
spec, or the swarm. kazi already is the layer that decides — with stored
evidence — whether any of them are actually done.

## Positioning

Canonical hero stands: *"Your coding agent says 'done.' kazi proves it."* /
*"the outer/reconciliation loop for coding agents"* / *"Kubernetes for coding
goals."* Borrowed frames for talks and threads: **"the referee for coding
agents,"** **"a while-loop with a referee,"** **"kubectl apply for software
outcomes."**

Differentiators, in order — each answers a live 2026 complaint:

1. **Deterministic predicates, not an LLM judge** — done is a predicate
   vector with stored evidence.
2. **Tamper-proof graders** (`read_only_paths`) — the direct, shippable
   answer to reward-hacking. Almost nobody else has this.
3. **Hard budgets + honest terminal states** (`converged` / `stuck` /
   `over_budget`) — answers "loops burn tokens forever."
4. **The goal is a versionable artifact** (`goal.toml`) — reviewable,
   diffable, re-runnable.
5. **Harness-agnostic** — drives Claude Code, Codex, opencode, Gemini CLI;
   improves for free as they do.
6. **Live predicates** — can require the *deployed* system correct, not just
   green-on-laptop.

## The star flywheel

```
one wow-demo + Show HN → front page → GitHub trending (star velocity)
      ↑                                        ↓
recurring benchmark posts              newsletters/bots scrape trending
(every model release)                  (TLDR, Console, Changelog, daily.dev)
      ↑                                        ↓
essays/field notes syndicated ← new users ← word of mouth ← next spike
```

Show HN yields ~1.4 stars/upvote and a 3–7 day newsletter cascade; trending
ranks on star *velocity* (~200+/24h for the main page). The durable projects
(Supabase, PostHog, Ollama, Astral) each paired one ignition moment with a
frictionless trial and a **repeating content engine** — kazi's trial is
already frictionless (`brew install`, no account); the engine is what we add.

## The recurring engine: the convergence benchmark

The single highest-leverage new asset — kazi's answer to aider's leaderboard.
On every major model release, publish:

> **The kazi convergence report, `<model>`:** N real goals driven by
> `kazi apply` under each harness × model. Per model: converged / stuck /
> over-budget counts, iterations, cost — **and gaming attempts**: enforcement
> violations and guard-predicate trips (delete-the-test, stub-the-function,
> edit-the-grader) kazi blocked.

The gaming-attempts column is the novel, headline-making part: no one else
can publish "we measured how often each frontier model tried to cheat,
because our controller is the thing that catches it." It rides other
companies' launch days as free distribution (the aider move) and attacks the
central risk head-on — the number has to hold up, and it's built to.

## The content system

| Tier | Job | Freshness mechanism |
| --- | --- | --- |
| Blog series (shipped) | The credibility ladder | Timestamped, done |
| **Essays** (`docs/essays/`) | One deep-dive per significant feature — gives adopters *arguments* (the htmx move) | A kazi **standing goal**: coverage + staleness ratchets, grader read-only to the agent |
| Field notes | Honest dogfood stories | Editorial |
| Benchmark reports | The recurring citable artifact | Reproducible methodology |

Named enemy across every essay: **"the agent's opinion of done."** First
essay shipped: *"The agent that deleted the failing test."*

## Channels — two tracks, one demo asset

- **Track B first (Elixir/BEAM):** small, high-trust, structurally
  predisposed to love an OTP reconciliation controller. ElixirForum + Hex +
  ElixirStatus (feeds ElixirWeekly/Radar automatically) shakes out install
  bugs before the crowd arrives.
- **Track A (AI-engineering):** Show HN is the main event; X/Bluesky demo
  clips; r/ClaudeAI, r/LocalLLaMA; awesome-claude-code / awesome-ai-agents
  lists; Console.dev, Changelog News; AI Engineer CFP.

Product Hunt is a low-priority checkbox weeks later; DevHunt/Peerlist are the
dev-native equivalents worth the small effort.

## Metrics — honest by construction

Stars are the visibility scoreboard, not the success metric (gameable; the
audience discounts raw counts). We track:

- **Install intents** (the ADR-0048 blog-attributed UTM signal) as the north
  star proxy — no telemetry exists on installed binaries, by design.
- **Star velocity around events** (launch day, each benchmark report) as the
  distribution health-check.
- **Ecosystem embeds** — awesome-list inclusions, downstream READMEs, harness
  marketplaces carrying kazi (the Ollama "be the dependency" measure).

## Risks and standing answers

- **Platform absorption** (Claude Code's own loop/goal features) → moat is
  deterministic multi-provider predicates, goal-as-artifact, ratchets, live
  probes, enforcement, harness-agnosticism.
- **Category education tax** → lead with borrowed frames, precise category
  second.
- **The benchmark number must hold up** → reproducible methodology, every
  figure traceable to a captured run (the Ruff lesson).
- **Maintainer bandwidth** → content system is kazi-maintained (standing
  goals dispatch drafts; a human reviews, doesn't author from scratch).
- **A flopped Show HN** → acceptable; re-launch after real progress is
  normal HN culture, and the benchmark engine supplies fresh material anyway.

## What we will not do

No star-buying or upvote solicitation. No hype vocabulary. No unshipped
capability shown as working. No engagement-bait controversy that spends the
credibility the proof discipline earns.

## The 90-day sequence

| Phase | Weeks | What |
| --- | --- | --- |
| 0 — Polish | 1 | Social-preview image, repo topics, Discussions/roadmap pin, final T25.10 accuracy gate |
| 1 — Elixir soft launch | 2 | Hex publish, ElixirForum post, podcast pitches |
| 2 — Show HN (main event) | 3–4 | HN post + first comment, same-day X/Bluesky thread, r/ClaudeAI + r/elixir |
| 3 — Cascade | 4–6 | Console.dev, Changelog News, awesome-lists, DevHunt/Peerlist, How I AI, Latent Space essay |
| 4 — Recurring engine | 6–12 | Convergence benchmark v1 + release-day cadence, essays cadence, CFPs, quarterly "kazi ships" week |

## Founder surface

Every breakout case has a human protagonist compounding attention across
launches. kazi's is distinctive: **the maintainer who ships by declaring
goals and letting kazi drive.** Show the real workflow — `/kazi plan` →
predicates → `kazi apply` → converged PR — including honest failures (`stuck`
escalations, budget stops, caught gaming attempts). The controller refusing a
shortcut is inherently serial, shareable content.

## Operator's one blocking decision

Pick the launch date. Everything above sequences from it. (Tracked as a
Blink task; the rest of the 90-day calendar schedules relative to it.)

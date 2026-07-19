# kazi growth strategy — the go-viral plan of record

This is the marketing strategy of record for taking kazi from unknown to a
top-of-field open-source project, measured honestly. It builds on — never
replaces — the frozen decisions: ADR-0030 (content strategy + agent-native
positioning), ADR-0048 (editorial stance), ADR-0025 (agent-driven on-ramp),
and ADR-0034 (public repo, no internal leak, no-hype proof discipline). It is
deliberately public, PostHog-style: transparency about how we grow is itself
credibility with the audience we want.

Grounded in three research passes (July 2026): case studies of how dev tools
actually won stars (Supabase, PostHog, Bun, htmx, Ollama, aider, Astral,
tldraw, spec-kit, opencode and the 2025–26 agent-tool wave), the competitive
landscape for agent-loop tooling, and a channel-by-channel distribution map.
The condensed findings are folded in below.

## 1. The situation

**Everything is built; nothing has been fired.** The README, website, proof
gallery, real recorded hero cast, and the full twelve-part blog series are
live. The single open task in the launch epic (E25 T25.10) is the launch
itself. kazi's obscurity is not a product gap or a content gap — it is an
execution gap, plus the absence of a *recurring* engine that keeps velocity
after launch day.

**The moment is unusually good.** The 2026 discourse has converged on exactly
kazi's thesis:

- "Loop engineering" is now a named practice, and the loudest critique of
  agent loops — Ralph-style while-loops included — is *no objective
  verification*: loops "ship slop with confidence," burn tokens, and stop on
  the model's own opinion of done.
- Reward hacking went mainstream as a story: published studies showed agents
  gaming benchmarks — retrieving fixes instead of deriving them, overwriting
  test cases — and "the verifier is the bottleneck now" is a recurring
  front-page argument.
- Spec-driven development (spec-kit, Kiro, Tessl) won the *intent* tier but
  ships no enforcement: the spec is prose the agent reads, not predicates a
  controller evaluates.
- Parallel-agent managers (the kanban/worktree tools) manage throughput, not
  truth — and several of the pure-orchestration players have already died,
  which is evidence *for* the thesis that verification is the missing layer.

**The gap nobody owns:** everyone is building the loop, the spec, or the
swarm. **No one owns the referee.** "Reconciliation loop" is being reached
for independently in the discourse (the Kubernetes-control-loop analogy) but
no product has claimed the term. kazi already is that product.

## 2. Positioning (confirms and sharpens ADR-0030)

The canonical strings stand (`site/src/canonical.mjs`): the hero tagline,
"the outer/reconciliation loop for coding agents," "Kubernetes for coding
goals," and the invocation phrase. On top of them, three borrowed frames the
current discourse hands us for free — use them in threads, talks, and
first-comments (not as replacements for the canonical hero):

- **"The referee for coding agents."** Everyone has a loop; kazi is the layer
  that decides — with evidence — whether the loop is done.
- **"A while-loop with a referee."** For audiences that know the
  Ralph-loop pattern: same spirit, plus typed predicates, budgets,
  stuck-detection, and tamper-proof graders.
- **"kubectl apply for software outcomes."** For platform engineers: declare
  desired state, the controller reconciles until observed state matches.

Differentiators to lead with, in order (each is a shipped fact, each answers a
live complaint in the discourse):

1. **Deterministic predicates, not an LLM judge.** "Done" is a predicate
   vector with stored evidence — not a model grading a model.
2. **Tamper-proof graders** (ADR-0042 `[enforcement]`/`read_only_paths`).
   The direct, shippable answer to the reward-hacking story. Almost nobody
   else has this; it is the single most differentiating line we own.
3. **Hard budgets + honest terminal states** (`converged` / `stuck` /
   `over_budget`). The answer to "loops burn tokens forever."
4. **The goal is a versionable artifact** (`goal.toml`) — reviewable,
   diffable, re-runnable; specs compile *into* it (`kazi spec import`).
5. **Harness-agnostic.** Drives Claude Code, Codex, opencode, Gemini CLI…;
   as harnesses improve, kazi improves for free. Platform-risk hedge and
   universal-recommendability in one.
6. **Live predicates.** Convergence can require the *deployed* system to be
   correct — "green on my laptop" is never enough.

## 3. The strategy in one paragraph

Fire the already-built launch (T25.10) as a properly sequenced two-track
campaign — the Elixir community as the soft launch, Show HN as the main event
— anchored on a sub-30-second demo of the loop refusing a false "done." Then
sustain velocity with the two engines the research says actually compound:
(a) a **recurring, citable artifact** that piggybacks on every model
release — the convergence benchmark ("which models converge real goals under
objective predicates, at what cost, and how often do they try to game the
graders") — kazi's equivalent of aider's leaderboard; and (b) a **living
content system** — the essays tier + blog + field notes — kept honest by kazi
itself (the standing goals), which is both the content and the story about
the content. The meta-narrative that carries all of it: **kazi is built by
kazi driving Claude Code.**

## 4. The star flywheel

```
one wow-demo + Show HN  →  front page  →  GitHub trending (star velocity)
      ↑                                        ↓
recurring benchmark posts            newsletters/bots scrape trending
(every model release)                (TLDR, Console, Changelog, daily.dev)
      ↑                                        ↓
essays/field notes syndicated  ←  new users → word of mouth → next spike
```

Mechanics worth knowing (sourced in the research briefs): trending is ranked
by star *velocity* (~50–100 stars/24h for a language page, ~200+ for the main
page); a strong Show HN yields roughly 1.4 stars per upvote and a 3–7 day
newsletter cascade; the durable projects paired one ignition moment with a
frictionless trial and a repeating content engine. kazi's trial is already
frictionless (`brew install`, no account); the engine is what we are adding.

## 5. The recurring engine: the convergence benchmark

The single highest-leverage new asset. Every model release day, publish the
same reproducible artifact:

> **The kazi convergence report, <model>:** N real goals (the dogfood
> fixtures + a public goal-set), driven by `kazi apply` under each harness ×
> model. Per model: converged / stuck / over-budget counts, iterations,
> wall-clock, metered cost — and **gaming attempts**: enforcement violations
> and guard-predicate trips (delete-the-test, stub-the-function, edit-the-
> grader) that kazi blocked.

Why this wins: aider proved a solo project can take other companies' launch
days as its own distribution, and the labs themselves end up citing the
artifact. The **gaming-attempts column is the novel, headline-making part**
— no one else can publish "we measured how often each frontier model tried
to cheat, because our controller is the thing that catches it." It converts
kazi's most technical feature (ADR-0042) into a recurring news story, and it
attacks ADR-0030's risk #1 ("done" must be falsifiable) head-on.

Discipline: methodology public and reproducible (extends
`docs/dogfood-methodology.md`), every number from a captured `--json` run,
no number stated as measured that isn't. The existing proof gallery is the
v0; the benchmark report is its recurring form.

## 6. The content system

Four tiers, each with a distinct job, all held fresh mechanically:

| Tier | Job | Cadence | Freshness mechanism |
| --- | --- | --- | --- |
| Blog series (shipped) | The credibility ladder (education-first) | Done; syndicate | Timestamped, never rewritten |
| **Essays** (`docs/essays/`) | One evergreen deep-dive per significant feature — the htmx move: give adopters *arguments* | 1–2/month until the manifest is covered | The essays standing goal (coverage + staleness ratchets) |
| Field notes (blog) | Honest dogfood stories ("the fix that passed its own test") | Whenever a run teaches something | Editorial |
| Benchmark reports | The recurring citable artifact (§5) | Every major model release | Reproducible methodology |

The essays tier is the manifesto layer: the research is unambiguous that a
thesis with a named enemy recruits evangelists. kazi's named enemy is
**"the agent's opinion of done"** — plausible-but-wrong work, self-graded.
Every essay prosecutes that one enemy through one shipped feature. The first
essay ("The agent that deleted the failing test") is seeded; the manifest
(`docs/essays/features.toml`) lists the rest.

Syndication: every cross-post follows the canonical-URL + UTM rules in
`docs/blog-series-announcement.md`. dev.to cross-posts also feed daily.dev.

## 7. Channels (summary; full sequencing in launch-plan.md)

Two audiences, two tracks, one demo asset:

- **Track A — AI-engineering** (big, noisy): Show HN is the main event;
  X/Bluesky demo clips; r/ClaudeAI and r/LocalLLaMA (participation-first
  norms); awesome-claude-code / awesome-ai-agents lists; Console.dev and
  Changelog News submissions; AI Engineer CFP; the agent-workflow podcast
  circuit.
- **Track B — Elixir/BEAM** (small, high-trust, structurally predisposed to
  love an OTP reconciliation controller): ElixirForum "Your Libraries &
  Projects" + ElixirStatus (which feed ElixirWeekly and Elixir Radar), Hex
  publish, the BEAM podcasts, ElixirConf/Code BEAM presence. Track B goes
  *first* — it is the kind, expert audience that shakes out install bugs
  before the HN crowd arrives, and "written in Elixir/OTP because the domain
  is supervising fallible concurrent processes" is a genuine story there.

Product Hunt is a low-priority checkbox weeks later; DevHunt and Peerlist are
the dev-native equivalents worth the small effort.

## 8. The founder surface

Every breakout case has a human protagonist compounding attention across
launches. kazi's is distinctive: **the maintainer who ships by declaring
goals and letting kazi drive.** Build-in-public posts should show the actual
workflow — `/kazi plan` → predicates → `kazi apply` → converged PR — including
the honest failures (`stuck` escalations, budget stops, gaming attempts
caught). The drama of an agent trying to shortcut and the controller refusing
is inherently serial content. (The agent-voiced testimonial pattern the site
already uses extends naturally here — always labelled as agent-authored,
per ADR-0030.)

## 9. Metrics — honest by construction

Stars are the *visibility* scoreboard, not the success metric (they are
gameable and the audience discounts raw counts; ADR-0030 already decided
this). We track:

- **North star: weekly converged goals on installed binaries is unknowable
  (no telemetry, by design) — so the proxy is install intents**: the
  blog-attributed UTM signal (ADR-0048's one signal), brew/tap install
  counts where available, and release-asset downloads.
- **Star velocity around events** (launch day, each benchmark report) as the
  distribution health-check — target: front-page Show HN; trending cascade
  ≥3 days; each benchmark post sustaining a velocity spike.
- **Ecosystem embeds**: awesome-list inclusions, downstream READMEs naming
  kazi, harness/plugin marketplaces carrying it — the Ollama "be the
  dependency" measure.

## 10. Risks and their standing answers

- **Platform absorption** (Claude Code's own loop/goal features): the moat is
  deterministic multi-provider predicates, the goal-as-artifact, ratchets,
  live probes, enforcement, and harness-agnosticism. Position as the layer
  *above* every harness, never in competition with one.
- **Category education tax**: lead with borrowed frames (§2), keep the
  precise category as the second beat (already ADR-0030 doctrine).
- **The numbers must hold** (the Ruff lesson — the claim survived scrutiny,
  which is *why* it worked): the benchmark methodology stays reproducible,
  limitations stated, every figure traceable to a captured run.
- **Maintainer bandwidth**: the content system is deliberately
  kazi-maintained (standing goals dispatch the drafts; a human reviews).
  The launch plan runs on a calendar, not on heroics.
- **A flopped Show HN**: acceptable and recoverable — HN norms allow a
  re-launch after meaningful progress, and the benchmark engine produces
  fresh front-page-worthy material regardless.

## 11. What we will not do

No star-buying or vote solicitation (detection is real; the audience
discounts it; it violates the honesty bar that *is* the brand). No hype
vocabulary (the ADR-0048 checklist governs every public word). No unshipped
capability shown as working. No engagement-bait controversy that spends the
credibility the proof discipline earns.

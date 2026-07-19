# kazi launch plan — the 90-day execution calendar

The sequenced execution of [strategy.md](strategy.md). The product launch gate
itself is owned by the plan (E25 T25.10 — the no-vaporware accuracy gate +
publish); this document is the distribution campaign around and after it.
Copy rules throughout: the ADR-0048 no-hype checklist, canonical strings
quoted verbatim from `site/src/canonical.mjs`, syndication per
`docs/blog-series-announcement.md`.

The **ready-to-paste copy** for the Phase 1–2 posts (Show HN title + first
comment, the X/Bluesky thread, the ElixirForum post, the r/ClaudeAI showcase)
lives in [launch-kit.md](launch-kit.md) — personalize the backstory lines and
post.

## Phase 0 — polish the conversion surface (week 1)

Everything below multiplies traffic; do these before sending any.

- [ ] **The 30-second wow clip.** One vhs/asciinema recording: an agent
  claims done → a predicate is red → `kazi apply` loops → vector flips green
  → `CONVERGED`. Committed `.tape`/`.cast` so it is reproducible (the
  existing `assets/proof-loop.cast` is the base; cut a tighter social edit).
  This is the shareable unit for every channel.
- [ ] **GitHub social preview** (Settings → Social preview, 1280×640): name +
  hero tagline + a terminal frame from the clip. This is what renders on
  X/Slack/HN link previews.
- [ ] **Repo topics** (~12): `claude-code`, `codex`, `coding-agent`,
  `ai-agents`, `agentic-coding`, `llm`, `developer-tools`, `cli`, `elixir`,
  `otp`, `automation`, `devops`.
- [ ] **README star-conversion check**: first screenful = tagline → clip →
  install one-liner (already true; verify after any edits). Pin the roadmap
  Discussion; enable Discussions categories for Show & Tell.
- [ ] **T25.10 gate**: run the accuracy/coherence checks, flip any stragglers,
  deploy, verify live.

## Phase 1 — Elixir soft launch (week 2)

The high-trust, expert audience first; it shakes out install bugs before HN
arrives, and it feeds its own newsletters automatically.

- [ ] Publish the core as a Hex package (dependents later feed "used by").
- [ ] ElixirForum post in *Your Libraries & Projects*: lead with the OTP
  story — a supervised population of fallible concurrent processes *is* the
  BEAM's home turf; one reconciler per goal, `GenStateMachine`, worktrees,
  SQLite read-model. Honest, architecture-forward, invite critique.
- [ ] Post to elixirstatus.com (feeds ElixirWeekly); the Forum + a blog post
  is the path into Elixir Radar (curation-based, no submission form).
- [ ] Share in the Elixir Slack/Discord announcements channels.
- [ ] Pitch Thinking Elixir / Elixir Wizards podcasts (both book community
  library authors).

Fix everything this audience surfaces. Target: a clean install story on all
three platforms and the first outside issues/PRs.

## Phase 2 — the main event: Show HN (weeks 3–4, Tue/Wed morning US)

- [ ] **Title:** `Show HN: Kazi – drives your coding agent until tests,
  probes, and budgets say done` (plain-capability pattern; no superlatives;
  A/B candidates kept in the launch kit — final call on the day).
- [ ] **Link the GitHub repo**, not the site.
- [ ] **First comment** (builder voice, per the researched structure): who I
  am → what it is in one sentence → the personal pain (an agent that said
  done and wasn't) → architecture and tradeoffs (Elixir/OTP, why predicates
  not an LLM judge, enforcement/read-only graders, budgets) → what it does
  NOT do (doesn't decide what to build; needs a harness on PATH; local
  models are the secondary path) → ask for critique.
- [ ] Be at the keyboard for 6+ hours; answer every substantive comment fast;
  never solicit upvotes.
- [ ] Same-day X/Bluesky thread: the clip + the before/after frame, repo
  link. Share the demo directly with a handful of AI-eng accounts who cover
  agent tooling (no ask, just the demo).
- [ ] r/ClaudeAI project showcase the following day (check sidebar rules
  day-of); r/elixir cross-post of the Forum thread. r/programming gets the
  *essay*, not the repo, later.

## Phase 3 — the cascade (weeks 4–6)

- [ ] Submit to Console.dev — email hello@console.dev (they review against
  public criteria; the repo already meets them).
- [ ] Submit to Changelog News — changelog.com/news/submit; separately pitch
  the interview show (an Elixir/Phoenix shop themselves; the OTP angle is a
  genuine in).
- [ ] Awesome-list PRs, each per that repo's CONTRIBUTING:
  awesome-claude-code (Multi-Agent Orchestration section), awesome-ai-agents,
  awesome-agents, awesome-elixir.
- [ ] DevHunt (PR-based listing) and Peerlist Launchpad (Monday cohorts) —
  cheap, dev-native. Product Hunt only as a zero-effort checkbox later.
- [ ] dev.to cross-post of essay #1 with `canonical_url` set (also feeds
  daily.dev).
- [ ] Podcast pitches: How I AI (screen-share format — pitch the live
  `/kazi plan` → `/kazi apply` demo, not the company); Changelog interview;
  a Latent Space *guest essay* (warm-intro / write-for-us path — pitch the
  reconciliation idea with kazi as the running example, not coverage of the
  tool).

## Phase 4 — the recurring engine comes online (weeks 6–12)

- [ ] **Convergence benchmark v1** (strategy §5): fixed public goal-set, the
  harness × model matrix, methodology doc extending
  `docs/dogfood-methodology.md`; publish the report page + the
  gaming-attempts (enforcement/guard trips) column. Announce with its own
  thread; this is designed to be citable.
- [ ] **Stand up the release-day play**: on every major model release, run
  the matrix, publish "kazi convergence report: <model>" within 24–48h, post
  to HN/X. This is the aider move — other companies' launch days become our
  distribution.
- [ ] Essays cadence: 1–2/month off the manifest
  (`docs/essays/features.toml`), each syndicated per the rules. The essays
  standing goal (`docs/essays/essays.goal.toml`) keeps coverage/staleness
  red until written — kazi dispatches drafts, a human reviews.
- [ ] AI Engineer CFP (watch the Sessionize wave): "Reconciliation, not
  vibes: machine-checkable goals for coding agents." PlatformCon as the
  secondary stage (the controller framing lands with platform engineers).
- [ ] Adopt a light **launch-cadence rhythm** (the Supabase lesson scaled to
  one maintainer): batch notable releases into a quarterly "kazi ships"
  week — each feature re-announced properly with its essay — rather than
  letting them dribble out unseen.

## Standing rules

- Every public claim traceable to a captured run; every command verified
  against `kazi help --json`; "coming" only where honest (ADR-0048).
- Every cross-post sets `rel=canonical` and uses `withUtm()` links
  (`docs/site-analytics.md`).
- Re-launching is allowed and planned: a flopped post is retried after real
  progress; features are re-announced when their essay ships.
- No internal-only detail in any public copy (ADR-0034).

## Success checks (see strategy §9)

Front-page Show HN; ≥3-day trending cascade; first benchmark report cited by
someone we don't know; install-intent signal trending up month-over-month;
3+ unaffiliated "who's using kazi" entries by day 90.

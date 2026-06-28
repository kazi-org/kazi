# Adoption blog series — editorial style sheet

This is the operational style sheet for the kazi adoption blog series. It is the
working checklist every post is reviewed against. It does **not** invent editorial
stance: it operationalizes the frozen decision in
[ADR-0048](adr/0048-adoption-blog-series-editorial-stance.md) and the epic
[`docs/plans/E38.md`](plans/E38.md). Where this sheet and ADR-0048 ever appear to
disagree, ADR-0048 wins — fix this sheet, do not re-decide the stance.

> **Where this lives.** The style sheet is committed at `docs/blog-style.md` rather
> than `site/src/content/blog/STYLE.md` because the blog content collection's glob
> (`**/*.{md,mdx}` in `site/src/content.config.ts`, owned by T38.1) would load a
> `.md` file under `site/src/content/blog/` as a *post* and reject it against the
> zod frontmatter schema, breaking `npm run build`. Keeping the sheet in `docs/`
> avoids that and is the location the epic explicitly sanctions. Post tasks
> (T38.6–T38.17) cite **this file**.

## Positioning source of truth (do not fork)

The series is the **long-form companion** to the short product surfaces
(README / website), not a competing rewrite (ADR-0048 dec. 6). Positioning is owned
by the canonical strings in **`site/src/canonical.mjs`** and by
[ADR-0030](adr/0030-content-marketing-agent-native-positioning.md). **Do not** introduce a
parallel positioning doc, and do not paraphrase the hook/category in your own words —
quote the canonical strings verbatim when a post needs them:

| Canonical string | Value |
| --- | --- |
| `HERO_TAGLINE` | `Your coding agent says "done." kazi proves it.` |
| `POSITIONING` | `the outer/reconciliation loop for coding agents` |
| `KUBERNETES_LINE` | `Kubernetes for coding goals` |
| `INVOCATION_PHRASE` | `have kazi drive this until done` |
| `INSTALL_CMD` | `brew install kazi-org/tap/kazi` |
| `HARNESSES` | `claude`, `opencode`, `codex`, `antigravity`, `claw`, `gemini_cli` |

If any of these change, the canonical file changes first and the posts follow — never
the reverse.

## The voice: fellow-traveler, never guru (ADR-0048 dec. 1)

You write as **someone who started where the reader is and hit the same walls** — not
as an authority handing down practice.

- **"Vibe coding" is the honest, productive starting point that everyone uses, the
  author included.** It is named with respect, never as a failing to be corrected. The
  series is about *what you reach for when you hit its ceiling*, not a put-down of the
  people standing under it.
- No lecturing, no "you should already know this," no condescension. A reader who is
  still at rung one should feel met, not scolded.
- Tell the story honestly: the wall was real, the fix was specific, the limitation
  that remained is what pushed you up the next rung.

A coherence check cannot catch condescension or hype — every post gets a **human voice
review** against this sheet before it ships (T38.18).

## Per-post template (ADR-0048; the required shape of every post)

Every post follows this five-beat arc:

1. **Hook** — open in the reader's world; a concrete, recognizable moment, not a
   thesis statement.
2. **The wall I hit** — the specific failure mode, told as a real (sanitized) story.
3. **The technique (tool-agnostic)** — the generic, reproducible practice that solves
   it. Lead with the commodity technique, not a tool name (see the private-stack rule).
4. **How to try it today** — concrete enough that a reader can apply it the same day
   with tools they already have.
5. **The limitation that motivates the next post** — end on the honest gap this rung
   does *not* close, so the series reads as one descent into the problem kazi solves.

## Every post is independently useful (ADR-0048 dec. 2)

Each post must **teach a real, mostly tool-agnostic technique the reader can apply the
same day, even if they never adopt kazi.** Credibility is earned by giving value away,
not by gating it behind the product. A reader who stops after post 4 should still feel
they got a fair trade. If a draft only makes sense as a step toward buying in to kazi,
it has failed this rule — rewrite it so the standalone technique is the payload.

## Separate the technique from the author's private stack (ADR-0048 dec. 5)

Much of the author's ladder runs on tools that are personal, internal, or not publicly
installable. A credibility series cannot ask a reader to reproduce a path half of which
they cannot obtain, and the public repo's no-internal-leak rule (ADR-0034) forbids
surfacing internal infrastructure. Therefore:

- **Lead with the GENERIC, reproducible technique** a reader can do with commodity
  tools (e.g. "give decisions a home," "verify against a real browser," "map callers
  before you refactor").
- **Name a specific tool only as "what I happened to use,"** clearly marked as
  illustration, and **always pair it with a commodity alternative** the reader can
  actually obtain.
- **No post may REQUIRE a private or internal tool to follow along.** If the only way
  to reproduce a step is a tool the reader cannot install, the step is wrong — find the
  commodity version.
- **Never leak internal hosts, IPs, paths, codenames, usernames, or "how we run it
  internally" detail** (ADR-0034). Genericize: say "a memory tool," "a browser-
  automation tool," "a code graph," "a deploy target," "a local model" — not the
  specific internal host or product name. This sheet models the rule: it names no
  internal infrastructure.

## Harness-agnostic (ADR-0048 dec. 5)

The techniques generalize **beyond any one tool OR coding agent.** The story is told
through one coding agent for concreteness, but each rung is framed so a reader on a
different harness (Codex, opencode, or any of the `HARNESSES` above) sees their own
path. Do not write a post that only works if the reader uses the same harness the
author did. When you show a harness-specific command, note that the *technique* is the
portable part.

## Name kazi late: the product emerges, it is not the premise (ADR-0048 dec. 5)

kazi is named **lightly, if at all,** in the early posts and only becomes the subject
once the progression has earned it (the final third). The product is the *conclusion*
of the ladder, not its premise. Per-post budget:

| Post | May name kazi? | How heavily |
| --- | --- | --- |
| 1 | No | Name no product (a single one-line forward pointer is the most allowed). |
| 2–7 | No | Techniques only. Post 7 visibly *prefigures* kazi (a written, checkable plan) but is still framed as a general practice — no product pitch. |
| 8 | Briefly | May name kazi as **ONE example** of the idea, **once, at the end** — a brief illustration, not a pitch, every command verified vs `kazi help --json`. |
| 9 | No (product) | Teaches the parallelism rung; does not pitch the product. |
| 10 | The category, not the product | Names the **category** ("a reconciliation loop for coding goals") before the product. |
| 11 | **Yes — the reveal** | kazi is the subject: the packaging of rungs 7–10 into a controller. Strictly what it does today. |
| 12 | Yes | The on-ramp: the wiring to drive kazi, the invocation phrase, an honest roadmap, a respectful call to try. |

## No-hype checklist (ADR-0048 dec. 3)

Reject a draft that does any of these:

- [ ] Uses "10x," "game-changer," "revolutionary," "AI-powered," or influencer voice.
- [ ] Makes an **unfalsifiable claim** ("never breaks," "always works").
- [ ] States a number as **measured** that is not reproducible.
- [ ] Reads as lead-generation rather than education in the early posts.
- [ ] Pitches the product before the progression has earned it (see the name-late map).
- [ ] Promises a capability kazi does not ship today without an honest "coming" label.

Prefer **specifics, real transcripts, and honestly-stated limitations.** This mirrors
ADR-0030's proof discipline and the project's "report honestly" rule.

## Accuracy checklist — no vaporware (ADR-0048 dec. 4)

Posts describe only **SHIPPED** behavior. Before a post ships, verify each:

- [ ] **Every kazi command, flag, and state named is verified against
  `kazi help --json`** (and `docs/concept.md` + the ADRs). The shipped command surface
  is: `apply`, `plan`, `status`, `approve`, `reject`, `list-proposed`, `init`, `help`,
  `version`. The verbs `run` and `propose` were **removed at v1.0.0** (ADR-0032) — they
  must never appear as a runnable `kazi <verb>` in a post. The site/blog verb-drift
  guard (T38.4) and the docs gate (`check-doc-commands.mjs`) scan for exactly this.
- [ ] **Every code example runs** — compiled/executed, not just pasted. A reader's first
  copy-paste must not error.
- [ ] **Every model id is checked against the claude-api reference** (the current
  Claude model ids). Do not hardcode a model id from memory; confirm it is current and
  spelled exactly, or refer to the model generically.
- [ ] **No number is stated as "measured" unless it is reproducible.** Aspirational or
  illustrative numbers are labelled as such.
- [ ] **"Coming" is used only where honest** — the claim must match the plan
  (`docs/plan.md` + `docs/plans/*.md`), and the capability must genuinely be planned,
  not invented.
- [ ] The post passes the same coherence/freshness gates as the rest of the site
  (E29/E31) and the series gate (T38.18).

## One story, reused assets (ADR-0048 dec. 6)

The series **reuses** the loop-transcript hero, the without/with frame, and the dogfood
"done" gallery (E25 assets T25.2 / T25.7) rather than minting parallel versions, and
links into the same launch. The README/site remain the one-screen pitch; the blog is
the credibility and education layer beneath them. A post that needs an E25 asset that
has not landed yet uses an honest placeholder/label until it does.

## The one adoption signal (ADR-0048 dec. 8)

The series is judged by **ONE** measurable signal, not by post count, page views,
or GitHub stars (ADR-0030: "instrument downloads/retention, not stars"):

> **Blog-attributed install intents** — outbound clicks from a blog page to the
> kazi repo/install that carry `utm_source=blog`. A doc → install progression
> measure, captured privacy-respectingly.

This is the conversion measure for the whole series. When you write or review a
post, the question that matters is "does this honestly move a reader toward
trying kazi?" — not "will this rack up views."

The wiring that makes the signal measurable (cookieless analytics, the UTM scheme
on outbound links, and the canonical-URL syndication rule) lives in
[`docs/site-analytics.md`](site-analytics.md). Two rules bind authors:

- **Outbound repo/install links use the UTM helper.** Build any outbound link to
  the repo/install with `withUtm()` (`site/src/utm.mjs`) so it carries
  `utm_source=blog`, `utm_medium=post`, `utm_campaign=vibe-to-reconciliation`,
  `utm_content=<slug>`. Never hand-append a query string — the scheme must not
  drift.
- **Syndicated copies set the canonical URL.** Every post already emits
  `<link rel="canonical">` to its `https://kazi.sire.run/blog/<slug>` permalink
  (automatic, via `Layout.astro`). Any cross-post (dev.to/Medium/Hashnode/etc.)
  MUST set its `rel=canonical` back to that permalink so authority stays on the
  kazi site and there is no duplicate-content penalty. T38.19 consumes this rule.

**Out of scope (ADR-0048):** no email capture, drip funnels, or gated lead
capture. RSS (`/blog/rss.xml`) is the subscription channel; this one signal is the
conversion measure.

---

## The series

- **Working title:** *From Vibe Coding to Reconciliation*
- **Canonical series slug:** `from-vibe-coding-to-reconciliation`
  (the series landing page is `site/src/pages/blog/from-vibe-coding-to-reconciliation.astro`).
- **Length:** twelve parts, published incrementally.
- **Arc:** each post ends on the limitation that motivates the next, so the series
  reads as one descent into the problem kazi solves.

### The twelve posts — titles, theses, and sub-beats

These match `docs/plans/E38.md` exactly. The sub-beats are the second-pass
(skills-coverage) review's missing rungs, folded in so the count stays twelve.

| # | Task | Title | Thesis | Sub-beats folded in |
| --- | --- | --- | --- | --- |
| 1 | T38.6 | **The ceiling of "looks good to me."** | The honest story of hitting the wall where a coding agent decides it is done and is subtly wrong. Land the thesis without selling: the bottleneck is not the model, it is the missing objective gate and missing durable structure — and the rest of the series is the ladder out. Name no product. | — |
| 2 | T38.7 | **Teach your agent to remember.** | The persistent-context rung: a project memory file, conventions, checkpoints — the agent that re-learns your repo every session vs the one that does not. Lead with the commodity technique (a committed conventions/memory file any agent reads); name the specific memory tooling only as illustration, with a commodity alternative. | — |
| 3 | T38.8 | **Decisions need a home: knowledge tiers (and keeping them honest).** | Architecture / decisions / operations / invariants as distinct homes (the design-doc / ADR / devlog / lore split) so settled choices are not re-litigated and findings are not re-derived. Prefigures kazi's self-maintaining-docs idea (E31) without pitching it. | **Knowledge maintenance** — knowledge rots: lint for contradictions/stale claims/orphan refs; tidy/trim for completed-work staleness; audit-docs for tier drift. |
| 4 | T38.9 | **Give your agent eyes (all the way to prod).** | Real-world verification: drive a browser, screenshot, exploratory-test, so "green locally" becomes "exercised live." Quietly plants kazi's live-predicate idea (verify against reality, not the agent's belief) without naming the product. | **Code → prod** — carry verification through to production: a release pipeline that ships the artifact, and triaging a stuck deploy layer by layer, so "done" means "running in prod." |
| 5 | T38.10 | **Stop re-reading the whole repo (and refactor without fear).** | Structural understanding + context economy: a code graph (callers, blast radius) and compressing what you feed the agent, for cheaper and sharper runs. Honest about when a graph helps and when grep is fine. | **Safe refactoring** — the same structural map lets you reshape code safely: map dependencies, propose an ordered change sequence that keeps the build green at each step. **Sidebar — research-as-graph:** ingest an external paper/post into your wiki and graph it to find cross-doc connections. |
| 6 | T38.11 | **From prompts to skills.** | Codifying the good prompt you keep retyping into a reusable skill — the compounding move from one-off cleverness to a workflow. Show the before (retyped prompt) and after (a skill) concretely; mention discovering/reusing skills others wrote as a one-liner, not a rung. | — |
| 7 | T38.12 | **Plan the work, then work the plan.** | Intent as an artifact: a checkable plan, tasks linked to outcomes, declared dependencies — vs an oral to-do list. The first rung that visibly prefigures kazi (a written, checkable contract); still framed as a general practice. | — |
| 8 | T38.13 | **A definition of "done" that can't lie.** | The credibility centerpiece: tests, coverage, wiring, live probes; why "the agent said done" is the wrong gate; what an objective gate looks like. Makes kazi's thesis (truth in the controller) feel necessary; may name kazi as ONE example, briefly, at the end. | **Adversarial review** — part of objective done is an adversary trying to break it: a security/red-team pass (injection, auth boundaries, invariant violations) and a deep review, scored, not a vibe. |
| 9 | T38.14 | **One developer, many agents (and how to recover).** | Parallelism without collisions: pools, claims, worktrees; coordinate on resources (blast radius), not identities — why task-locks alone do not prevent two agents editing the same files. Builds credibility for concept Gap 2. | **Resilience** — a preflight check before fanning out (auth, disk, build, stale worktrees) and resuming a halted run without redoing finished work; plus a one-paragraph "ad-hoc crew vs planned pool" distinction. |
| 10 | T38.15 | **The pattern underneath: reconciliation.** | The conceptual turn: every rung above is the same loop — declare desired state, drive an agent, check against reality, repeat. The CI / Kubernetes analogy (borrowed frames per ADR-0030); truth lives in the controller. Names the category before the product. | **It generalizes** — the same loop governs your own work-in-progress, not just the running system: checkpoint the desired end-state, drive, resume/re-check on interruption; a stuck deploy is reconciliation applied to the deploy stack. |
| 11 | T38.16 | **Meet kazi: "done," proven.** | The product, finally, as the packaging of rungs 7–10 into a controller: declare a goal as predicates, the agent drives kazi, it converges or stops honestly (`stuck` / `over_budget`). Use the real loop transcript (E25 T25.2) and the without/with frame; document the invocation phrase. Strictly what kazi does today. | — |
| 12 | T38.17 | **Your on-ramp.** | Close the series: recap the ladder; you can start at any rung; the copy-paste wiring to drive kazi from Claude Code; an honest "where it is going" (no vaporware); a respectful call to try it. Link the dogfood "done" gallery (E25 T25.7) as proof. | **Harden first** — before you let an agent run unsupervised, audit your harness (hooks, permissions, MCP servers, secrets) so you trust the loop you are about to hand the keys to. |

### Deliberately excluded (ADR-0048)

Do **not** add posts for these — they were considered and left out on purpose:

- A hierarchical "agent organization" post (CEO/C-suite/VPs/Leads delegation) — a
  different product philosophy, not a rung toward kazi's thesis.
- Email drip funnels / gated lead capture / welcome sequences — the site is static and
  gated capture cuts against the developer-respecting stance. RSS (the feed at
  `/blog/rss.xml`, T38.4 — published posts only) is the subscription channel; the one
  adoption signal (T38.21) is the conversion measure.
- A separate team/role charter for producing the series — the work runs under the
  existing `/apply --pool`; this style sheet carries the voice/quality bar.

## Supporting tasks

- **T38.20 — visual assets (shipped):** explanatory diagrams in the site's visual
  language (the ADR-0018 cyan→blue→violet gradient on the ink `#0b1220` surface),
  **not** glossy ad creative. Every image carries descriptive alt text.

  **Visual language.** Diagrams are hand-authored, optimised **SVG** (vector, so they
  stay crisp at any size and theme-neutral as self-contained dark panels, matching the
  diagrams under `site/public/diagrams/`). No raster/stock imagery, and no removed CLI
  verbs — the `check:commands` guard scans `.svg` too, so name only commands the CLI
  ships today (e.g. `kazi apply`).

  **What exists (reuse before adding):**
  - `site/public/proof-loop.gif` — the loop **convergence transcript**, a real
    recorded `kazi apply` cast (home + README; source cast at `assets/proof-loop.cast`,
    T25.2). Reused, not duplicated.
  - `site/public/diagrams/reconcile-loop.svg` — the reconcile **cycle** (observe →
    diff → dispatch → re-observe → decide, with the "still failing → dispatch again"
    feedback arc and the converged / stuck / over-budget exits). Distinct from the
    transcript above.
  - `site/public/diagrams/ladder.svg` — the twelve-rung ladder, vibe coding (bottom)
    → reconciliation (top).
  - `site/public/diagrams/before-after.svg` — the without/with contrast.
  - `site/public/blog/art/part-01.svg` … `part-12.svg` — per-post header art, one per
    post, generated by `site/scripts/gen-post-art.mjs` (re-run to regenerate). Each is
    a 16:9 banner with the part number, short title, and a ladder-position marker.
    `site/public/blog/art/alt.json` holds the matching alt strings.

  **Where they render.** The three core diagrams render on the series landing page
  (`/blog/from-vibe-coding-to-reconciliation`) under "See the loop, the ladder, and
  the contrast"; the per-post art renders as a thumbnail on each of the twelve part
  rows. When a post ships (T38.6–T38.17), wire its art as the post header via the
  T38.1 frontmatter — `ogImage: /blog/art/part-NN.svg` and `heroAlt:` set from the
  matching `alt.json` entry — and the `[...slug].astro` layout renders it as the
  header image. (Note: SVG is ideal for the in-page header; for social-card OG a PNG
  render is preferable, and the site-wide `og-image.png` remains the default card.)
- **T38.21 — instrumentation:** ONE measurable adoption signal (not vanity metrics),
  privacy-respecting analytics appropriate to a static site, a UTM scheme on outbound
  links, and a canonical-URL syndication rule. The named signal is **blog-attributed
  install intents** (see [The one adoption signal](#the-one-adoption-signal-adr-0048-dec-8)
  above); the wiring is documented in [`docs/site-analytics.md`](site-analytics.md).

## References

- [ADR-0048 — Adoption blog series: editorial stance](adr/0048-adoption-blog-series-editorial-stance.md) (the authority)
- [ADR-0030 — Content marketing and agent-native positioning](adr/0030-content-marketing-agent-native-positioning.md)
- [ADR-0025 — Docs lead with the agent-driven on-ramp](adr/0025-docs-lead-with-agent-driven-onramp.md)
- [ADR-0034 — OSS gates: docs land with the code, no internal-info leak](adr/0034-oss-contribution-gates-docs-with-code-no-leak.md)
- Canonical positioning strings: `site/src/canonical.mjs`
- The epic and full per-post detail: [`docs/plans/E38.md`](plans/E38.md)

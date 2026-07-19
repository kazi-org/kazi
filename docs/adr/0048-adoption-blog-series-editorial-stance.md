# ADR 0048: Adoption blog series -- editorial stance

## Status
Accepted

## Date
2026-06-25

## Builds on
ADR-0025 (docs lead with the agent-driven on-ramp) and ADR-0030 (content-marketing
and agent-native positioning). ADR-0025/0030 govern the SHORT surfaces -- the
one-screen README and website that pitch the product. This ADR governs a different
surface: a long-form, multi-part blog series that builds credibility through
education rather than a pitch. It reuses ADR-0030's assets (the loop transcript, the
without/with frame, the dogfood "done" gallery) instead of inventing parallel ones.

## Context

kazi is about to be announced to a wider audience. The product rests on a set of
ideas that are easy to state and easy to dismiss in one line -- "done" should be an
objective gate, truth should live in a controller and not in the agent, agents that
edit the same files should coordinate on blast radius. Stated cold, to an engineer
who has not felt the underlying pain, these read as either obvious or as
over-engineering.

The author did not arrive at these ideas top-down. They arrived by starting where
almost everyone starts -- a vanilla coding-agent CLI, prompting by feel -- and then
hitting a sequence of concrete walls, each of which was solved by reaching for one
more piece of structure: persistent context, a place for decisions to live,
real-world verification, a structural view of the codebase, reusable skills, a
written plan, an honest definition of done, safe parallelism. kazi is the
conclusion of that progression, not its premise.

That progression is itself the most credible argument for the product. A reader who
walks the same path -- and picks up useful, tool-agnostic techniques at each step --
arrives at kazi's core ideas already convinced they are necessary, because they have
felt the gap each one closes. A series that tells the story honestly is therefore a
durable adoption and SEO asset, and a respectful on-ramp for engineers who are still
at rung one.

The risk is framing. The plan and the ADRs ship in a PUBLIC repo, and the series is
public-facing. The wrong tone -- talking down to "vibe coders," influencer hype,
unfalsifiable claims, naming the product on every line, or describing capabilities
kazi does not yet have -- would actively repel the exact audience (working
engineers) the series is meant to win. Engineers reward specificity and honesty and
punish salesmanship. The series must earn trust before it asks for adoption.

## Decision

Publish a twelve-part narrative blog series on the kazi website (`/blog`, working
title **"From Vibe Coding to Reconciliation"**) that walks a reader from a vanilla
coding-agent workflow to a reconciliation workflow, governed by the following
editorial stance. The series is tracked as epic E38.

1. **Fellow-traveler, never guru.** The author writes as someone who started where
   the reader is and hit the same walls -- not as an authority handing down
   practice. "Vibe coding" is named as the honest, productive starting point that
   everyone uses (including the author), never as a failing to be corrected. The
   series is about what you reach for when you hit its ceiling, not a put-down of the
   people standing under it.

2. **Every post is independently useful.** Each post must teach a real,
   mostly tool-agnostic technique the reader can apply the same day, even if they
   never adopt kazi. Credibility is earned by giving value away, not by gating it
   behind the product. A reader who stops after post 4 should still feel they got a
   fair trade.

3. **Credibility over hype.** No "10x," no influencer voice, no unfalsifiable
   claims. Prefer specifics, real transcripts, and honestly-stated limitations.
   This mirrors ADR-0030's proof discipline and the project's "report honestly"
   rule: any number stated as measured must be reproducible; anything aspirational
   is labelled as such.

4. **No vaporware.** Posts describe only SHIPPED behavior. Every kazi command, flag,
   and capability named in a post is verified against `kazi help --json`,
   `docs/concept.md`, and the ADRs, and the series is gated by the same
   coherence/freshness checks as the rest of the site (E29/E31). A post may say a
   capability is "coming" only if it is honestly labelled and the claim matches the
   plan.

5. **The product emerges; it is not the premise.** kazi is named lightly, if at all,
   in the early posts and only becomes the subject once the progression has earned
   it (the final third of the series). Early posts name the specific tools the author
   used (a memory tool, a browser-automation tool, a code graph, and so on) as
   illustrations of a technique -- "what I reached for" -- never as "what you must
   install." The techniques generalize beyond any one tool OR harness: the story is
   told through one coding agent for concreteness, but each rung is framed so a reader
   on Codex/opencode/any harness sees their own path.

   **Separate the technique from the author's private stack.** Much of the author's
   ladder runs on tools that are personal, internal, or not publicly installable. A
   credibility series cannot ask a reader to reproduce a path half of which they
   cannot obtain, and the public repo's no-internal-leak rule (ADR-0034) forbids
   surfacing internal infrastructure. Therefore each post leads with the GENERIC,
   reproducible technique (e.g. "give decisions a home," "verify against a real
   browser") that a reader can do with commodity tools, and names a specific tool only
   as "what I happened to use," clearly marked, with a commodity alternative noted.
   No post requires a private or internal tool to follow along, and none leaks
   internal hosts, paths, or codenames.

6. **One story, reused assets, two surfaces.** The series is the long-form
   companion to ADR-0030's short surfaces, not a competing rewrite. It reuses the
   loop-transcript hero, the without/with frame, and the dogfood "done" gallery
   rather than minting parallel versions, and it links into the same launch. The
   README/site remain the one-screen pitch; the blog is the credibility and
   education layer beneath them. The positioning source of truth is the existing
   canonical strings (`site/src/canonical.mjs`) and ADR-0030; the series does not
   introduce a parallel positioning doc.

7. **Show the loop; don't only describe it.** A series whose climax is "the
   reconciliation pattern" cannot be text-only -- the reader must SEE the loop, the
   ladder, and the without/with contrast. The series ships a small set of explanatory
   DIAGRAMS (the reconcile loop, the rung ladder, before/after) and per-post header
   art, in the site's visual language -- technical diagrams, NOT glossy ad creative,
   consistent with credibility over hype. Existing site/README assets are reused
   before any are generated, and every image carries descriptive alt text.

8. **Instrument for one honest adoption signal, not vanity.** Per ADR-0030
   ("instrument downloads/retention, not stars"), the series declares ONE measurable
   success signal tied to adoption (e.g. blog-attributed installs/skill-wires or a
   doc-to-install progression), with privacy-respecting analytics appropriate to a
   static site, UTM tagging on outbound links, and a canonical-URL strategy for any
   syndication (so cross-posts do not incur a duplicate-content penalty or bleed the
   canonical's authority). The series is judged by that signal, not by post count or
   star spikes. Heavyweight lifecycle marketing (email drip funnels, gated capture) is
   out of scope (see "Considered and deliberately excluded").

The twelve posts and their per-post theses are specified in `docs/plans/E38.md`. The
arc is: (1) the ceiling of agent-decided "done"; (2) persistent context; (3)
knowledge tiers (and keeping them honest); (4) real-world verification (and code ->
prod); (5) structural code understanding, context economy, and safe refactoring; (6)
prompts becoming skills; (7) intent as a written plan; (8) an honest definition of
done (including adversarial/security review); (9) safe parallelism across many agents
(and resilience/recovery); (10) the reconciliation pattern underneath all of it; (11)
kazi as the packaging of rungs 7-10; (12) the reader's on-ramp (and hardening the
harness before unsupervised runs). The added themes ride as sub-beats on existing
posts so the count stays twelve; the per-post detail and the two supporting tasks
(visual assets, instrumentation) are in `docs/plans/E38.md`.

## Considered and deliberately excluded

To keep the series credible and on-message -- and to stop a well-meaning execution
pass from bolting marketing machinery onto it -- the following were considered and
deliberately left out:

- **A hierarchical "agent organization" post (CEO/C-suite/VPs/Leads delegation).**
  Out of scope: that is a different product philosophy (role-based delegation), not a
  rung toward kazi's thesis (objective done + resource-level coordination). Including
  it would dilute the arc. Post 9 covers the parallelism rung that matters for kazi
  (coordinate on blast radius, not identity).
- **Email drip funnels / gated lead capture / welcome sequences.** Out of scope: the
  site is static (GitHub Pages) with no backend, and gated capture cuts against the
  developer-respecting, anti-hype stance. RSS (already planned) is the
  developer-appropriate subscription channel; the one adoption signal (decision 8) is
  the conversion measure, not an email list.
- **A separate team/role charter for producing the series.** Out of scope: the work
  is executed by the existing `/apply --pool`; the editorial style sheet (E38 T38.5)
  carries the voice/quality bar that a charter would otherwise hold.

## Consequences

**Positive.**

- The strongest case for kazi's ideas is made experientially -- the reader feels each
  gap before the product is offered as the close -- which is far more durable than
  asserting the ideas cold.
- Twelve evergreen, individually-useful posts are a compounding SEO and credibility
  asset, and a respectful on-ramp that meets engineers at whatever rung they occupy.
- The "every post independently useful" and "name the product late" rules make the
  series safe to share in communities that are allergic to marketing, widening
  distribution beyond a launch spike.
- Because posts describe only shipped behavior and are coherence-gated, the series
  cannot drift into advertising vaporware -- protecting the credibility it is built to
  create.

**Negative / cost.**

- Twelve quality posts are a real, sustained writing investment; the series will be
  published incrementally, not all at once, and the plan sequences it so.
- The no-vaporware accuracy gate adds per-post verification overhead (every command
  checked against the live CLI), and the gate blocks publication of the full set
  until green.
- Naming the product late trades some short-term conversion for long-term
  credibility; the early posts will not read as direct lead-generation, and that is
  deliberate.
- Tone is hard to enforce mechanically; a written editorial style sheet (E38 T38.5)
  and a human review pass per post are required, because a coherence check cannot
  catch condescension or hype.
- The visual-assets and instrumentation decisions (7, 8) add production surface
  beyond writing -- diagrams to make and an analytics/canonical-URL setup to wire --
  which is why they are scoped as two bounded tasks (E38 T38.20/T38.21), held to
  "diagrams not ad creative" and "one signal not a funnel," not open-ended.

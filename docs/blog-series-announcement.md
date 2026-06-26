# Series announcement + cross-post kit (T38.19)

This is the launch kit for the twelve-part adoption blog series
*From Vibe Coding to Reconciliation* (epic [E38](plans/E38.md)). It is the copy
that announces the series and the rules for syndicating it — drafted against the
editorial bar in [`docs/blog-style.md`](blog-style.md) and the frozen stance in
[ADR-0048](adr/0048-adoption-blog-series-editorial-stance.md).

It leads with the **pain**, not the product (ADR-0048 dec. 1/5): agents that say
"done" but aren't, and the ladder out. kazi is the *conclusion* of that ladder,
not the headline.

## Scope: educational announcement, not the product launch

This kit announces the **educational series**. It deliberately does **not** rewrite
the product launch copy. The product launch — the README/site hero, the loop
transcript, the without/with frame, and the Show HN / X copy that leads with the
human → Claude → kazi → Claude spine — is owned by **E25 T25.10** (the single
no-vaporware launch gate). The two coordinate so **one launch links both**:

- **E25 T25.10** is the PRODUCT launch (what kazi is, how you wire it).
- **T38.19** (this kit) is the SERIES announcement (the credibility/education
  layer beneath it).

When T25.10 publishes the product announcement, it links the series landing page
(`/blog/from-vibe-coding-to-reconciliation`); this kit links back to the product
on-ramp. Neither restates the other's positioning. Where positioning strings are
needed, both quote `site/src/canonical.mjs` **verbatim** — the canonical file is
the single source of truth and neither surface paraphrases it.

## The canonical anchor

The **canonical URL** for the announcement is the series landing page:

> **https://kazi.sire.run/blog/from-vibe-coding-to-reconciliation**

Use it as the primary link in every channel. When linking a single representative
post instead (for a thread that opens on the pain), use Part 1's permalink:

> **https://kazi.sire.run/blog/the-ceiling-of-looks-good-to-me/**

Both pages already emit `<link rel="canonical">` to their own
`https://kazi.sire.run` permalink (automatic, via `site/src/layouts/Layout.astro`;
see [`docs/site-analytics.md`](site-analytics.md)). That is what makes the
canonical-syndication rule below enforceable.

## The announcement (canonical copy)

Lead with the pain and the ladder; name the product late. This is the long-form
blurb for the blog index, a README pointer, a LinkedIn/newsletter intro, or the
first comment on an aggregator post.

> **From Vibe Coding to Reconciliation — a hands-on ladder out of "looks good to me."**
>
> You know the moment. You describe a task to your coding agent, it comes back a
> minute later with a tidy diff and a cheerful "Done." You skim it, it looks
> good, you move on — and days later it is subtly wrong. The bottleneck was never
> the model. It was the missing objective gate, and the missing durable structure
> around the work.
>
> This is a twelve-part series about what you reach for when you hit that ceiling.
> Vibe coding is the honest, productive place everyone starts — the author
> included. The series is the ladder up from it, one rung per post, each one a
> real technique you can apply the same day with tools you already have:
>
> 1. The ceiling of "looks good to me" — why "the agent said done" is the wrong gate.
> 2. Teach your agent to remember — persistent context instead of re-learning your repo every session.
> 3. Decisions need a home — knowledge tiers, and the hygiene that keeps them honest.
> 4. Give your agent eyes — real verification, all the way to prod.
> 5. Stop re-reading the whole repo — structural understanding and safe refactoring.
> 6. From prompts to skills — codify the prompt you keep retyping.
> 7. Plan the work, then work the plan — intent as a checkable artifact.
> 8. A definition of "done" that can't lie — tests, coverage, wiring, live probes.
> 9. One developer, many agents — parallelism without collisions, and how to recover.
> 10. The pattern underneath: reconciliation — every rung is the same loop.
> 11. Meet kazi — the packaging of those rungs into a controller.
> 12. Your on-ramp — the copy-paste wiring, an honest roadmap, a respectful call to try.
>
> Each post is independently useful — stop at any rung and you still come out
> ahead. By the top, the rungs collapse into one idea: declare the desired state,
> drive an agent, check against reality, repeat. That is reconciliation, and it is
> what **kazi** does — *the outer/reconciliation loop for coding agents*.
>
> Start the series → https://kazi.sire.run/blog/from-vibe-coding-to-reconciliation

The two emphasized strings above quote `site/src/canonical.mjs` verbatim:
`HERO_TAGLINE` (`Your coding agent says "done." kazi proves it.` — the pain framing
the opener echoes) and `POSITIONING` (`the outer/reconciliation loop for coding
agents`). Do not paraphrase them; if they change, the canonical file changes first
and this kit follows.

## The thread (X / HN style)

Pain first, ladder second, product last. No hype words ("10x", "game-changer",
"revolutionary"), no unfalsifiable claims, no measured numbers that aren't
reproducible (the no-hype checklist, ADR-0048 dec. 3). Every kazi verb named is a
shipped verb (`apply`, `plan`; `run`/`propose` were removed at v1.0.0 and must
never appear).

```
1/ Your coding agent says "done." You skim the diff, it looks good, you ship it.
   Days later it's subtly wrong. The bottleneck was never the model — it was the
   missing objective gate. A 12-part series on the ladder out. 🧵

2/ Start where everyone starts: prompting by feel. It's honest and it's
   productive. This isn't a put-down of vibe coding — it's about what you reach
   for when you hit its ceiling.

3/ Rung 1: a definition of "done" the agent can't fake. "It looks good to me" is
   not a gate. Tests green, the endpoint actually live, the change actually
   deployed — that's a gate.

4/ Rung 2: teach your agent to remember. A committed conventions/memory file any
   agent reads, so it stops re-learning your repo every session.

5/ Rung 3: give decisions a home. Architecture, decisions, operations, invariants
   as distinct homes — so settled choices aren't re-litigated and findings aren't
   re-derived.

6/ Rung 4: give your agent eyes. Drive a real browser, screenshot, exercise it
   live — so "green on my laptop" becomes "verified against reality."

7/ Rungs 5–9: stop re-reading the whole repo (a code graph + context economy),
   turn your best prompt into a skill, write a checkable plan, and run many agents
   without them colliding — coordinate on blast radius, not identities.

8/ Rung 10: it's all one loop. Declare the desired state, drive an agent, check
   against reality, repeat until it's objectively true — or it stops and tells you
   why. That's reconciliation. Truth lives in the controller, not the agent.

9/ Rung 11: that loop, packaged, is kazi — the outer/reconciliation loop for
   coding agents. You declare a goal as predicates; your agent drives kazi; it
   converges, or stops honestly (stuck / over_budget). You never run it yourself —
   Claude does.

10/ Each post stands alone — start at whatever rung you're on. Full series:
    https://kazi.sire.run/blog/from-vibe-coding-to-reconciliation
```

A shorter single-post variant, anchored on Part 1 for an aggregator submission:

```
Title: The ceiling of "looks good to me"
Link:  https://kazi.sire.run/blog/the-ceiling-of-looks-good-to-me/

First comment:
Your coding agent says "done." You skim the diff, it looks good — and days later
it's subtly wrong. The bottleneck was never the model; it was the missing
objective gate. This is part 1 of a 12-part series on the ladder out: persistent
context, knowledge tiers, real verification, structural understanding, skills, a
checkable plan, an honest definition of done, safe parallelism — and the loop
underneath all of it. Each post is independently useful. No product pitch until
the progression earns it.
```

## Canonical-URL syndication rule (apply to every cross-post)

Republishing a post on an external platform (dev.to, Medium, Hashnode, a
newsletter, etc.) is fine — but it **MUST** point search-engine authority back at
the original so there is no duplicate-content penalty. This consumes the rule in
[`docs/site-analytics.md`](site-analytics.md) (T38.21) verbatim:

1. **Set `rel=canonical` to the kazi permalink.** Every syndicated copy sets its
   canonical URL to the original `https://kazi.sire.run/blog/<slug>` permalink.
   - **dev.to:** add `canonical_url: https://kazi.sire.run/blog/<slug>` to the
     article front matter.
   - **Medium:** import the post via *Stories → Import a story* (it sets the
     canonical automatically), or set it under the story's *Settings → Advanced*.
   - **Hashnode:** set *Original article URL* (the canonical field) in post
     settings.
   - **Hand-rolled HTML / newsletter web copy:** add
     `<link rel="canonical" href="https://kazi.sire.run/blog/<slug>">` to the
     `<head>`.
2. **Carry the UTM scheme on links back to the repo/install.** Any outbound link
   to the repo or install from a syndicated copy uses the fixed series UTM scheme
   so the click is attributable to the one adoption signal — **blog-attributed
   install intents** (ADR-0048 dec. 8). Build the link with the
   `withUtm(target, content)` helper (`site/src/utm.mjs`); never hand-append a
   query string, so the scheme can never drift:

   | Param | Value |
   | --- | --- |
   | `utm_source` | `blog` |
   | `utm_medium` | `post` |
   | `utm_campaign` | `vibe-to-reconciliation` |
   | `utm_content` | the post slug, the series slug, or `blog-index` |

   For example, the repo link for a Part 1 cross-post is
   `withUtm("https://github.com/kazi-org/kazi", "the-ceiling-of-looks-good-to-me")`,
   which produces:

   ```
   https://github.com/kazi-org/kazi?utm_source=blog&utm_medium=post&utm_campaign=vibe-to-reconciliation&utm_content=the-ceiling-of-looks-good-to-me
   ```

3. **Don't fork positioning.** Syndicated copy uses the same canonical strings
   (`site/src/canonical.mjs`) as the original — never a paraphrased pitch.

Out of scope (ADR-0048): no email capture, drip funnels, or gated lead capture.
RSS (`/blog/rss.xml`) is the subscription channel; blog-attributed install intents
is the one conversion measure.

## "Learn more" links (README + site)

- **README** points to the series from the header link row (next to Website /
  Concept / Releases) so a GitHub reader can reach the educational ladder.
- **Site nav** links `/blog` on every page (home, blog index, series landing,
  every post) via the shared header; the blog index leads with the flagship
  series and links its landing page.

Both are wired in this change. The series landing page is the canonical anchor
above.

## References

- [E38](plans/E38.md) — the epic (T38.19 is this kit; deps T38.18, T38.21).
- [ADR-0048](adr/0048-adoption-blog-series-editorial-stance.md) — editorial stance (the authority).
- [`docs/blog-style.md`](blog-style.md) — the style sheet (voice, name-late map, no-hype + accuracy checklists).
- [`docs/site-analytics.md`](site-analytics.md) — the UTM scheme + canonical-syndication rule this kit consumes (T38.21).
- [`docs/blog-series-review.md`](blog-series-review.md) — the T38.18 gate record (the facts this announcement matches).
- `site/src/canonical.mjs` — canonical positioning strings (quote verbatim, never paraphrase).
- `site/src/utm.mjs` — `withUtm()`, the outbound-link helper.
- E25 T25.10 — the PRODUCT launch gate this kit coordinates with (does not duplicate).

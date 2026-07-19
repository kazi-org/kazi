# Adoption blog series — T38.18 accuracy, coherence & quality gate

This is the recorded series-level review for the twelve-part adoption blog series
*From Vibe Coding to Reconciliation* (epic E38). It is the single no-vaporware gate
(T38.18): a human read of the whole set plus the mechanical accuracy/coherence
checks, run once against the full, published series. It operationalizes the bar in
[`docs/blog-style.md`](blog-style.md) and
[ADR-0048](adr/0048-adoption-blog-series-editorial-stance.md).

- **Date:** 2026-06-26
- **Scope:** all 12 posts under `site/src/content/blog/` (parts 1–12; the
  `welcome.md` placeholder is `draft: true` and excluded from the production build).
- **Series:** `From Vibe Coding to Reconciliation`, slug
  `from-vibe-coding-to-reconciliation`.
- **Verdict:** GREEN. No accuracy, leakage, or voice failures found. One
  test-coverage gap (no explicit prev/next navigation test) was closed additively.

## The twelve posts (verified order)

| # | Slug | Title | Names kazi? (budget) |
| --- | --- | --- | --- |
| 1 | the-ceiling-of-looks-good-to-me | The ceiling of "looks good to me" | No — no product named |
| 2 | teach-your-agent-to-remember | Teach your agent to remember | No |
| 3 | decisions-need-a-home | Decisions need a home: knowledge tiers | No |
| 4 | give-your-agent-eyes | Give your agent eyes (all the way to prod) | No |
| 5 | stop-re-reading-the-whole-repo | Stop re-reading the whole repo | No |
| 6 | from-prompts-to-skills | From prompts to skills | No |
| 7 | plan-the-work-then-work-the-plan | Plan the work, then work the plan | No (prefigures, no pitch) |
| 8 | a-definition-of-done-that-cant-lie | A definition of "done" that can't lie | Once, at the end |
| 9 | one-developer-many-agents | One developer, many agents | No |
| 10 | the-pattern-underneath-reconciliation | The pattern underneath: reconciliation | Category only |
| 11 | meet-kazi-done-proven | Meet kazi: "done," proven | The reveal |
| 12 | your-on-ramp | Your on-ramp | On-ramp |

## Gate results

### (a) Command / flag / state / capability accuracy — PASS

- Every `kazi <verb>` used across the set (`apply`, `plan`, `install-skill`,
  `approve`, `reject`, `list-proposed`, `status`, `help`) is a live verb in
  `lib/kazi/cli.ex`. The removed verbs `run` and `propose` appear **nowhere**.
- Verified by the E29 guards run locally: `node site/scripts/check-commands.mjs`
  with `BLOCKING=1` ("site command-accuracy OK"), and
  `node .github/scripts/check-doc-commands.mjs` ("doc command-accuracy OK; 26 docs
  scanned; 15 commands, 28 flags").
- Terminal states named in posts 8/10/11/12 — `converged` / `stuck` /
  `over_budget` — match `docs/concept.md` and the controller.

### (b) Every code example runs — PASS

- `brew install kazi-org/tap/kazi` matches `INSTALL_CMD`; `kazi install-skill`,
  `/kazi plan`, `/kazi apply`, `kazi list-proposed`, `kazi approve`, `kazi reject`,
  `kazi status`, `kazi help --json` are all real verbs.
- The atomic git-lease example in post 9 was executed in a throwaway repo: the
  first `git update-ref refs/leases/orders-module HEAD 000…0` succeeds (exit 0),
  the second fails with "reference already exists" (non-zero) — exactly the
  create-or-fail semantics the post documents.
- `git worktree add …` commands are standard git. The JS (`sendEmail`) and the
  `PLAN.md` / `safe-refactor` markdown blocks are valid illustrative snippets. No
  hardcoded model ids appear anywhere (checked: no `opus`/`sonnet`/`haiku`/
  `claude-*`/`gpt-*`/`gemini-*` ids in any post body), so there is nothing to drift.

### (c) No number stated as measured unless reproducible; roadmap honestly labelled — PASS

- No fabricated/measured performance numbers (no "10x", no benchmark figures
  presented as measured). Illustrative caller counts ("14 call sites", "lap 1/2/3")
  are clearly illustrative, not measurements.
- The illustrative convergence transcript in post 11 is explicitly labelled "It is
  illustrative, not a recorded run — a recorded cast … is **coming**".
- Roadmap items in posts 11/12 are labelled `coming` / `planned` / `in progress`
  and each matches the live plan: recorded cast + dogfood gallery (E25 / dogfood
  fixtures), native parallel scheduling (E21/ADR-0027), dependency-aware predicate-
  graph waves (E23/ADR-0028), more harnesses incl. the recently-added Gemini CLI
  profile (E37), and self-maintaining docs as a standing goal (E31).

### (d) Private-stack rule + no internal leakage — PASS

- No post requires a private/internal tool to follow along. Where the author's own
  stack is referenced it is genericized and paired with a commodity alternative:
  "a memory tool" (post 2), "a small doc linter"/"a routine that archives" (post 3),
  "a code graph" + grep fallback (post 5), security/deep-review as repeatable skills
  (post 8), preflight/resume/crew-vs-pool framed generically (post 9), harness audit
  framed tool-agnostically (post 12).
- `SCAN_TREE=1 .github/scripts/no_internal_leak_guard.sh` over the full tree:
  "No internal-marker leaks found. PASS." No private IPs/hosts/paths/codenames/
  usernames in any post.

### (e) Intra-series cross-links + prev/next resolve — PASS

- `npm run build` is clean (15 pages incl. all 12 posts, the series landing page,
  index, rss; `welcome` excluded as a draft).
- A crawl of every internal `href` in `dist/` (15 HTML files) found **0 broken
  internal links** and **0 images without `alt`**.
- The per-post `rel="prev"`/`rel="next"` chain forms a single linear ladder Part 1
  → Part 12 (Part 1 has no prev; Part 12 has no next). The post-12 recap links to
  all eleven prior posts and all resolve.

### (f) Voice + continuity (human read of the whole set) — PASS

All twelve posts were read end-to-end. The voice is consistent and on-stance:

- **Fellow-traveler, not guru.** Every post opens in the reader's world with a
  first-person "the wall I hit" story ("mine included", "I lost a day", "kept alive
  by coffee"). Vibe coding is named as the honest, productive starting point, never
  as a failing. No condescension, no "you should already know this".
- **No hype.** No "10x"/"revolutionary"/"game-changer"/influencer voice; no
  unfalsifiable claims. Costs are stated honestly ("this is real work, and it is
  never quite finished"; "the no-hype rule cuts both ways").
- **Naming budget respected exactly.** Posts 1–7 name no product (they name the
  reader's *harness* — Claude Code/Codex/opencode — which the harness-agnostic rule
  requires, but never kazi). Post 8 names kazi once, at the end ("That is the one
  time I will name it"). Post 9 names no product. Post 10 names the *category* using
  the canonical strings verbatim ("the outer/reconciliation loop for coding agents",
  "Kubernetes for coding goals"). Post 11 is the reveal; post 12 the on-ramp.
- **Canonical strings quoted verbatim** where used: `HERO_TAGLINE`, `POSITIONING`,
  `INSTALL_CMD`, `INVOCATION_PHRASE` ("have kazi drive this until done") — matching
  `site/src/canonical.mjs`.
- **One arc.** Each post recaps the rungs below it and ends on the specific
  limitation that motivates the next (gate→memory→tiers→eyes→graph→skills→plan→
  objective-done→parallelism→reconciliation→kazi→on-ramp). The continuity is tight:
  post 6's `safe-refactor` skill is post 5's procedure; post 8 answers post 7's "who
  decides it's true?"; post 10 collapses all nine rungs into one loop; post 11
  packages it; post 12 hands over the keys. The ladder reads as one descent into the
  problem kazi solves.

### (g) Images, smoke, Lighthouse, README↔site coherence — PASS

- Every image carries non-empty `alt` (dist crawl: 0 missing; per-post hero art and
  the three core diagrams asserted by the existing spec).
- Playwright: **112 passed** (`/blog`, the series landing page, all 12 post routes,
  instrumentation, visual assets, draft 404). The one gap — no explicit prev/next
  navigation test — was closed by adding a `prev/next navigation (T38.18)` describe
  block (Part-1 has next-no-prev, Part-12 has prev-no-next, and a forward walk of
  the full Part 1→12 chain).
- Lighthouse (headless) on `/blog` and `/blog/the-ceiling-of-looks-good-to-me/`:
  **SEO 100, accessibility 100** on both — above the ≥90 bar.
- README↔site coherence (T9.9): `node site/scripts/check-coherence.mjs` —
  "README <-> website coherence OK (5 canonical strings match)".

## Fixes applied in this change

- Added the `blog post prev/next navigation (T38.18)` Playwright describe block to
  `site/tests/blog.spec.mjs` to certify the in-series pager (the only gate gap).

No post content required correction: the series passed accuracy, leakage, and voice
review as published.

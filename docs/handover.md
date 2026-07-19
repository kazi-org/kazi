# Handover — 2026-07-19, session 01a33eba (kazi growth-strategy / Track C)

## TL;DR
Extended `docs/marketing/strategy.md` with agent-discoverability "Track C"
and shipped the agent-executable pieces (llms.txt, MCP registry metadata,
one essay). Drafted + gisted a LinkedIn field note (real, verified OAuth
vacuous-convergence run from `coachblink/blink`, genericized). Everything
committed and pushed to `claude/kazi-viral-marketing-nhq3fl`
(commit `bb710b3f`). Next action: no open PR yet for this branch — open one
against `main` when ready, and separately decide whether/when to open the
mcp.so / Smithery / glama.ai / awesome-mcp-servers listing PRs the
metadata file was prepared for.

## Done & VERIFIED
- `llms.txt` (repo root), `docs/marketing/mcp-registry-listing.md`,
  `docs/essays/verifying-work-when-you-dont-pick-the-agent.md` — all
  committed, pushed. Essay checker run clean:
  `python3 docs/essays/check_essay_coverage.py` → no integrity errors,
  `harness-agnostic` now covered (was previously uncovered).
- Strategy docs amended: `docs/marketing/strategy.md` §7/§9,
  `strategy-summary.md`, `docs/plans/E25.md` (new T25.13),
  `docs/marketing/operator-tasks.md` (new OP-21).
- `docs/marketing/social/linkedin-oauth-vacuous-convergence.md` — reviewed
  by the operator (David rewrote the body), one clause added back defining
  kazi on first mention per his instruction. Mirrored to a **secret** gist:
  https://gist.github.com/dndungu/c88592c1d1fe1d0b22c32fd8791fab14 (kept in
  sync — last `gh gist edit` matches the committed file).
- Source claim verified firsthand (not taken on faith): grepped
  `coachblink/blink`'s `docs/roadmap.md`/`docs/devlog.md` and confirmed
  `T-MCP.4` really converged green then was hand-rejected as vacuous
  (hardcoded auth stub, non-random codes, open redirect) — 2026-07-19 entry,
  held out of the PR, not merged. The LinkedIn draft is genericized (no
  project name) per the operator's explicit call.
- Branch `claude/kazi-viral-marketing-nhq3fl` pushed to origin, commit
  `bb710b3f` visible on remote (`git ls-remote` — not re-checked after this
  write, but push returned success with no rejection).

## Done but UNVERIFIED
- Whether David has actually posted the LinkedIn piece yet — not observed,
  not my action to take (his call, his account).
- No PR open for this branch against `main` — deliberately not opened;
  wasn't asked to, and these are draft/reference marketing docs, not a
  ship-ready feature. Confirm with the operator whether this should become
  a PR or stay as branch WIP for further iteration.

## In flight
- **T25.13** (`docs/plans/E25.md`) marked `- [ ]` (not done) — the
  agent-executable parts (llms.txt, essay, metadata block) are done; the
  registry-PR-opening parts (mcp.so, Smithery, glama.ai,
  `punkpeye/awesome-mcp-servers`) and the two ownership-gated submissions
  (official MCP registry, Claude Code plugin marketplace = **OP-21**) are
  explicitly NOT done — they touch third-party repos/accounts and were left
  for the operator or an explicit go-ahead.
- Current branch has no open PR. Next session (or David) should either open
  one or fold this into a broader E25 push.

## Blocked
- None. Nothing in this session required another lane/owner to unblock.

## Running processes left alive
- None. `kazi status` reported "no LIVE runs (safe to install/upgrade
  kazi)" at session end — this session never launched a kazi converge.

## Landmines & context
- The blog content collection (`site/src/content.config.ts`) hard-caps
  `series`+`part` to 1–12 and requires both — you cannot add a standalone
  blog post outside the 12-part "From Vibe Coding to Reconciliation" series
  without a schema change. That's why the field-note/comparison content
  went into `docs/essays/` (feature-anchored, `covers:` ids from
  `features.toml`) instead of `site/src/content/blog/`.
- `docs/essays/check_essay_coverage.py` hard-fails (`--check`, exit 1) on
  any essay whose `covers:` id isn't in `features.toml`, or whose anchor
  path doesn't exist — verify against it before adding a new essay.
- Two OTHER worktrees exist on this machine
  (`/Users/dndungu/Code/kazi-org/worktrees/e50-safe-concurrent-work`,
  `.../sonnet-default-tier-flip`) — not touched, not mine this session, left
  alone per the no-touch-others'-worktrees rule.
- Three claims are currently held by other sessions
  (`refs/claims/T25.10`, `T67.6`, `T68.6`) — none released or touched by me;
  I held zero claims this session.
- The "Track C" naming/registry submission work assumes `kazi mcp`'s tool
  list in `lib/kazi/mcp/server.ex` stays the source of truth — the metadata
  file explicitly says to re-verify the tool list there before submitting,
  since it grows.

## How to resume
1. `git fetch origin && git checkout claude/kazi-viral-marketing-nhq3fl`
   (already the branch this was done on — no separate handover branch was
   needed since it was already remote-tracked).
2. Read this file, then `docs/marketing/strategy.md` §7 (Track C) and
   `docs/plans/E25.md` T25.13 for the full task shape.
3. Decide: open a PR for this branch now, or keep iterating. If continuing
   registry submissions, `docs/marketing/mcp-registry-listing.md` has the
   paste-ready metadata for mcp.so/Smithery/glama.ai/awesome-mcp-servers.
4. No `/claim` needed to resume — nothing here was claimed, it's plain
   branch work.

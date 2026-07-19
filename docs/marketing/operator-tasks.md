# Launch operator tasks — the human-only list

The subset of [launch-plan.md](launch-plan.md) that requires a human: account
ownership, judgment calls, live presence, or actions on services an agent
cannot (or should not) drive. Formatted as discrete, assignable tasks so they
can be loaded into the operator's task tracker as-is. Everything not on this
list is agent-executable and runs through the ordinary kazi/plan workflow.

Status legend: `todo` / `doing` / `done`. Keep this file the single source of
truth for launch-ops state; tick items here as they complete.

## Gate (before anything ships)

| id | task | phase | est | status |
| --- | --- | --- | --- | --- |
| OP-1 | Approve the launch: confirm T25.10's accuracy gate is green and give the go date | 0 | 15m | todo |
| OP-2 | Record (or approve the cut of) the 30-second social edit of the proof cast | 0 | 1h | todo |
| OP-3 | Set the GitHub social-preview image and repo topics (repo Settings — owner-only) | 0 | 15m | todo |
| OP-4 | Enable/verify GitHub Discussions categories; pin the roadmap discussion | 0 | 15m | todo |

## Accounts and identity

| id | task | phase | est | status |
| --- | --- | --- | --- | --- |
| OP-5 | Confirm the X/Bluesky accounts that will carry the launch (project and/or personal), bios pointing at the repo | 0 | 30m | todo |
| OP-6 | Get a lobste.rs invite via the Elixir community and participate for 2–3 weeks before any kazi submission | 1 | ongoing | todo |
| OP-7 | Create the Hex.pm account/org and approve the first package publish | 1 | 30m | todo |

## Launch-day presence (cannot be delegated)

| id | task | phase | est | status |
| --- | --- | --- | --- | --- |
| OP-8 | Post the ElixirForum thread under your own name; answer replies for 48h | 1 | 3h | todo |
| OP-9 | Post the Show HN (your account, repo link, prepared first comment) on the agreed Tue/Wed morning; stay at the keyboard 6+ hours answering everything | 2 | 1 day | todo |
| OP-10 | Same-day X/Bluesky thread with the clip; share the demo 1:1 with a handful of AI-eng accounts (no ask attached) | 2 | 2h | todo |
| OP-11 | r/ClaudeAI showcase post next day (re-read sidebar rules first); r/elixir cross-post | 2 | 1h | todo |

## Submissions (human sender preferred)

| id | task | phase | est | status |
| --- | --- | --- | --- | --- |
| OP-12 | Email hello@console.dev with the pitch + repo | 3 | 30m | todo |
| OP-13 | Submit to changelog.com/news/submit; separately pitch the interview show | 3 | 45m | todo |
| OP-14 | Pitch How I AI with a concrete live-demo outline | 3 | 45m | todo |
| OP-15 | Pitch Thinking Elixir / Elixir Wizards | 1–3 | 45m | todo |
| OP-16 | Draft + submit the Latent Space guest essay (idea-first, kazi as example) | 3–4 | 4h | todo |
| OP-17 | AI Engineer CFP submission when the Sessionize wave opens; PlatformCon as secondary | 4 | 2h | todo |
| OP-21 | Submit `kazi mcp` to the official MCP registry (namespace/ownership proof required) + Claude Code plugin marketplace submission form | 3 | 1h | todo |

## Recurring (after week 6)

| id | task | phase | est | status |
| --- | --- | --- | --- | --- |
| OP-18 | On each major model release: approve + post the convergence report within 48h | 4+ | 2h each | todo |
| OP-19 | Monthly: review/bump `reviewed:` on essays the standing goal flags, approve syndication | 4+ | 1h/mo | todo |
| OP-20 | Quarterly: pick the "kazi ships" week and approve its lineup | 4+ | 1h/qtr | todo |

Agent-executable counterparts (awesome-list PRs, DevHunt/Peerlist listings,
dev.to cross-posts with canonical URLs, benchmark harness construction, essay
drafts, `llms.txt` authoring, mcp.so/Smithery/glama.ai listing PRs) are
intentionally NOT here — they run through the normal workflow and only need
OP-level approval where noted (OP-21 covers the two registries that require
proven account/namespace ownership).

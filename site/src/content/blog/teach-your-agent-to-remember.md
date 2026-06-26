---
title: "Teach your agent to remember"
description: "Your coding agent starts every session as a stranger to your repo — re-guessing your conventions, re-proposing the thing you already rejected. The fix is not a smarter model; it is a place where context persists across sessions. This is the second rung: give your agent a memory it reads before it touches a line of code."
date: 2026-06-25
author: "kazi team"
tags:
  - vibe-coding
  - coding-agents
  - persistent-context
  - series-from-vibe-coding-to-reconciliation
series: "From Vibe Coding to Reconciliation"
part: 2
draft: false
ogImage: /blog/art/part-02.svg
heroAlt: 'Header art for Part 2 of "From Vibe Coding to Reconciliation": Teach your agent to remember. A rung-2-of-12 position marker on the kazi gradient.'
---

You open a fresh session, describe a task, and watch your coding agent — Claude
Code, Codex, whichever you reach for — confidently re-learn things it learned
yesterday. It opens three files to rediscover where your tests live. It picks the
HTTP client you migrated away from two months ago. It suggests, with real
enthusiasm, the exact approach you and it agreed not to take last week. None of
this is malice or stupidity. The agent simply has no memory. Every session, it
meets your repo as a stranger.

In Part 1 I argued that the ceiling of "looks good to me" is built from two
missing pieces: no objective gate, and no durable structure. The checklist trick
at the end of that post — write down what "done" means before you start —
addresses the first gap a little. This post is about the second one, and it is
the cheapest, highest-leverage move in the whole series. You can do it this
afternoon, with no new tool, and feel the difference on your very next task.

## The wall I hit

The thing that finally wore me down was not a dramatic bug. It was repetition. I
noticed I was typing the same paragraph into the agent over and over: *we use the
standard library HTTP client, not the third-party one; tests go next to the code,
not in a separate tree; don't touch the generated files in that directory; we
decided against an ORM here, queries are hand-written.* Every session. Sometimes
twice a session, because a long conversation would drift and the agent would
forget what I told it forty messages ago.

Worse than the typing was what happened when I forgot to paste it. One morning I
gave a quick instruction without the usual preamble, and the agent did a tidy,
well-reasoned thing that directly contradicted a decision we had made — together,
in writing, in a previous session it could no longer see. It re-opened a question
that was closed. The code looked fine. It passed Part 1's gate. It was also a
small step backward, because the reasoning behind the original decision now lived
nowhere except my head and a transcript I would never scroll back to.

That is the durable-structure gap made concrete. The agent's quality on any given
run depended on how much context I happened to remember to paste. Good days and
bad days, and the only thing separating them was my memory, not the agent's.

## The technique: give the agent a memory it reads first

The fix is almost embarrassingly simple, and it is entirely tool-agnostic: **put
the context that does not change into a file that lives in the repo, and make the
agent read it at the start of every session.** Not pasted fresh each time —
committed, version-controlled, sitting next to the code it describes.

Most coding agents already have a convention for exactly this. Claude Code reads
a `CLAUDE.md` at the project root. Several other agents — including Codex-style
tools — read an `AGENTS.md`. Some editors read a dotfile of rules. The filename
differs by harness; the idea does not. It is a plain-text brief the agent loads
before it does anything else, so the things you were re-typing become things it
already knows. If your agent has no such convention, you lose nothing: keep a
`CONVENTIONS.md` in the repo and paste it (or tell the agent to read it) as the
first line of a session. The portable part is the *committed file*, not any one
tool's magic filename.

What goes in it? Exactly the paragraph you keep re-typing, made permanent:

- **Conventions that are not obvious from the code.** Which HTTP client, where
  tests live, what to never touch, the formatter you run before committing.
- **Decisions you do not want relitigated.** "We chose hand-written queries over
  an ORM here, on purpose." One line each. The *why* matters more than the *what*,
  because the why is what stops the agent from cheerfully re-proposing the
  alternative.
- **How to actually run and check things.** The build command, the test command,
  the one environment quirk that bites every newcomer — human or agent.

Keep it short and keep it true. A memory file that drifts out of sync with the
code is worse than none, because the agent will trust it. Treat it like code:
when a convention changes, the file changes in the same commit.

The deeper point is that this file is shared memory for *two* forgetful parties.
The agent reads it every session. So do you, three weeks from now, when you have
forgotten why the queries are hand-written. You are not just teaching the agent to
remember; you are giving your own future self a place to have left a note.

## How to try it today

You do not need to adopt anything. Next session, before you ask for any code:

1. Create the file your agent reads at startup — `CLAUDE.md`, `AGENTS.md`, or a
   `CONVENTIONS.md` you paste in yourself. Check it into the repo.
2. Seed it from memory: write the paragraph you are tired of re-typing. Five
   bullet points is plenty to start. Conventions, the build/test commands, and
   one or two decisions-with-reasons.
3. Work a normal task. Every time you catch yourself explaining something the
   agent "should have known," stop and add that line to the file instead of just
   saying it in chat. The file grows by accretion, from real friction, which is
   the only way it stays honest.

Within a few sessions you will have a brief that turns a cold-start stranger into
something closer to a returning colleague — and the diff quality stops depending
on what you remembered to paste.

A note on the fancier version, so I am not hiding the ball. Part of my own setup
goes beyond a single file: I reached for a memory tool that records individual
facts as it works and recalls the relevant ones automatically at the start of a
session, so I do not have to curate one growing document by hand. That is a
convenience, not a requirement, and you can get most of its value with the
commodity version — the committed file above, plus the discipline of appending to
it whenever you repeat yourself. Lead with the file. Reach for automation only
once the file is paying off and the upkeep starts to chafe. The technique is the
file; the tool is just how much of the upkeep you hand off.

## The limitation this leaves open

Here is the honest gap, and it is the reason there is a Part 3. The single memory
file works beautifully right up until it doesn't — and the way it fails is by
succeeding too well. You start adding to it. Conventions, then a couple of
architectural decisions, then a debugging gotcha you never want to hit again, then
operational notes about the deploy. Six weeks later it is a 400-line wall, and the
agent (and you) skim it, which means the one line that mattered gets lost in the
noise. A flat memory file has no notion that "which HTTP client we use," "why we
chose this architecture," "the migration that corrupted a populated table once,"
and "how to deploy" are *different kinds* of knowledge with different lifespans
and different readers.

So the next rung is structure: giving decisions, architecture, operational
findings, and hard-won invariants distinct homes, so settled choices are not
relitigated and painful lessons are not re-derived — and so the file you ask the
agent to read first stays short enough to actually be read. That is where this
series goes next.

This is Part 2 of a twelve-part ladder, from prompting by feel to a workflow where
"done" is something the system can prove rather than something you hope is true.
Each rung stands on its own. If you do only one thing from this post, write the
file — it is the smallest change in the series with the largest immediate return.

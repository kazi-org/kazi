---
title: "Decisions need a home: knowledge tiers (and keeping them honest)"
description: "The single memory file works right up until it becomes a 400-line wall where settled decisions get relitigated and hard-won lessons get re-derived. The fix is to give different kinds of knowledge different homes — and a small habit to keep them from rotting. This is the third rung: structure your project's memory, then keep it honest."
date: 2026-06-25
author: "kazi team"
tags:
  - vibe-coding
  - coding-agents
  - knowledge-management
  - series-from-vibe-coding-to-reconciliation
series: "From Vibe Coding to Reconciliation"
part: 3
draft: false
ogImage: /blog/art/part-03.svg
heroAlt: 'Header art for Part 3 of "From Vibe Coding to Reconciliation": Decisions need a home: knowledge tiers. A rung-3-of-12 position marker on the kazi gradient.'
---

You did the thing from last time. You gave your agent a memory file, committed it
to the repo, and watched it pay off immediately. So you kept feeding it.
Conventions first, then the reasoning behind a big architecture call, then a
deploy runbook, then the note about the migration that once corrupted a populated
table and must never run that way again. One morning you open the file to add a
line and you cannot find where the last one went. It is four hundred lines now.
You skim it. Your agent skims it. The single line that would have stopped today's
mistake is in there — three screens down, sitting next to nine lines that stopped
being true months ago.

That is Part 2's success turning into Part 2's failure. A flat memory file has no
notion that "which HTTP client we use," "why we chose this architecture," and "the
migration that once ate a table" are *different kinds* of knowledge — with
different lifespans, different readers, and different rules about when you are
allowed to change them. Pile them together and they bury each other.

## The wall I hit

Two things happened in the same week, and together they made the point.

First, the agent cheerfully re-proposed switching to an ORM — the exact decision
we had made *against*, on purpose, with reasons. The line recording that choice
was still in the file. It had just been pushed down and surrounded by unrelated
operational notes, so neither the agent nor I surfaced it in time. A closed
question got reopened because the answer no longer had a findable address.

Second, in a different corner of the same file, the note about that dangerous
migration was buried just as deep — and a teammate re-hit the bug it warned
about. The lesson had been learned once, written down once, and then lost in the
pile. We paid for it twice.

Same root cause both times. One undifferentiated heap. A decision that should be
permanent and a finding that is already history were stored the same way, with no
structure telling them apart. The memory file had taught the agent to remember; it
had not taught it to remember things *as the kinds of things they are*.

## The technique: give each kind of knowledge a home

The move is to split that one file into a few, organized not by topic but by
**lifespan and reader**. Four homes cover almost everything, and none of them
requires a tool you cannot get:

- **Architecture — how the system is shaped.** A design doc: the major pieces,
  how they fit, the shape of the data. It changes only when the shape does, which
  is rarely.
- **Decisions — what you chose and why.** A decision log. The well-known commodity
  format is the ADR (Architecture Decision Record): one short, dated entry per
  decision — context, choice, the alternative you rejected, consequence. The rule
  that makes it work: a decision is *frozen* once made. You do not edit it when you
  change your mind; you write a new one that supersedes it. That is what stops the
  relitigating — the reasoning has a permanent address.
- **Operational findings — what happened.** An engineering journal, dated entries
  appended over time: this benchmark came back at this number, this is the
  debugging session where I found the boundary bug. It grows fast, and that is
  fine; it is history, not law.
- **Invariants and landmines — what must never happen again.** A short "lore" or
  gotchas file. The migration that ate a table. The flag whose name means the
  opposite of what it does. Append-only, greppable, blunt — the file you grep
  *before* you touch something scary.

The test for which tier a line belongs in is one question: **when does this stop
being true?** Architecture stops being true when you rebuild. A decision never
does — you supersede it instead. A finding is already in the past, so you just
date it. An invariant never stops being true; that permanence is the point. If you
cannot answer the question for a line, it is probably two lines wearing a trench
coat — split it.

The immediate payoff: your memory file shrinks back to a short index that points
at the four homes. The agent reads a lean brief and follows a link when it needs
depth. Settled choices stop being reopened because they have somewhere to live;
lessons stop being re-derived because there is a journal to grep first.

## Knowledge rots — so the technique has a second half

Here is the part nobody warns you about. The moment you have four files instead
of one, they start to drift. A decision gets superseded but the design doc still
describes the old shape. A finding hardens into an invariant but stays stranded in
the journal. A link points at a file someone renamed. Tiers without upkeep are not
an improvement over one messy file — they are four messy files and a false sense
of order.

So the second half of the technique is a small maintenance habit. Roughly once a
week, spend ten minutes doing three things:

- **Hunt contradictions and stale claims.** Does any tier assert something another
  tier (or the code) now disproves? The design doc is the usual offender.
- **Trim completed work.** A finished task or a closed plan item is now noise.
  Archive it out of the live docs so what remains is all still live.
- **Check for drift between tiers.** Is operational detail leaking into the design
  doc? Did a hard-won invariant get logged as a passing note in the journal? Move
  things to the tier that matches their lifespan.

You can automate the mechanical parts. I reach for a small doc linter that flags
dead cross-references and contradictions, and a routine that archives completed
items for me. But none of that is required, and you should not start there. The
commodity version is a recurring calendar reminder, `grep` for dead links, and
your own eyes for ten minutes. Lead with the habit; reach for tooling only once it
is paying off and the manual upkeep starts to chafe.

Be honest about the cost, because the no-hype rule cuts both ways: this is real
work, and it is never quite finished. What you buy with it is the genuinely
expensive thing — not re-deriving a lesson you already learned, not reopening a
question you already closed. It is a trade that has paid off for me, not a freebie.

You can probably feel where this is heading. The upkeep is mechanical enough that
you start wishing something would just *watch* the tiers and flag the drift the
way a test suite watches your code — keep the knowledge honest without you
remembering to. Hold that thought; it comes back later in the series.

## How to try it today

1. Split your memory file into four homes: a design doc, a decision log, a
   journal, and a lore/gotchas file. The names do not matter — the *homes* do. For
   the decision log, the ADR format is a documented, copy-pasteable starting point.
2. Triage every existing line with the one question: *when does this stop being
   true?* That single test sorts almost everything.
3. Leave the original memory file as a short index that points at the four. Keep it
   short enough that the agent — and you — actually read it.
4. Put a real recurring reminder on your calendar: ten minutes, once a week, to
   grep for dead links, trim finished work, and move anything sitting in the wrong
   tier. That reminder *is* the maintenance habit. Everything else is optional
   automation.

Do this and the agent stops relitigating closed decisions, the team stops
re-hitting buried landmines, and the brief you ask the agent to read first stays
lean instead of swelling into another wall.

## The limitation this leaves open

Here is the honest gap, and it is the reason there is a Part 4. Everything in this
post is still about *words*. Your tiers can be pristine, your decisions
addressable, your invariants greppable, your agent perfectly briefed — and the
code can still be quietly broken in a real browser, or not actually deployed at
all. Part 1's objective gate lives in unit tests; Parts 2 and 3 gave that gate and
its context durable homes. None of it has *eyes on the running system*. Knowledge
about the work is not evidence that the work works.

So the next rung is verification that reaches reality: giving the agent eyes —
driving a real browser, exercising the change live, carrying "green locally" all
the way to "running in production." That is where this series goes next.

This is Part 3 of a twelve-part ladder, from prompting by feel to a workflow where
"done" is something the system can prove rather than something you hope is true.
Each rung stands on its own. If you do only one thing from this post, ask every
line in your notes when it stops being true — and give it a home that matches.

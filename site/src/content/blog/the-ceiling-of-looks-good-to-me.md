---
title: 'The ceiling of "looks good to me"'
description: "Where prompting-by-feel quietly breaks: your coding agent decides it is finished, you skim the diff, it looks good, and days later it is subtly wrong. The bottleneck is not the model — it is the missing objective gate and the missing durable structure. This is the first rung of the ladder out."
date: 2026-06-25
author: "kazi team"
tags:
  - vibe-coding
  - coding-agents
  - definition-of-done
  - series-from-vibe-coding-to-reconciliation
series: "From Vibe Coding to Reconciliation"
part: 1
draft: false
ogImage: /blog/art/part-01.svg
heroAlt: 'Header art for Part 1 of "From Vibe Coding to Reconciliation": The ceiling of "looks good to me". A rung-1-of-12 position marker on the kazi gradient.'
---

You know the moment. You describe a task to your coding agent — Claude Code,
Codex, opencode, whichever you reach for — and a minute later it comes back with
a tidy diff and a cheerful summary. "Done. Added pagination to the list
endpoint, with tests." You skim it. The code reads clean. The tests are green.
It looks good to me. You merge.

That feeling — *looks good to me* — is the most productive starting point in
software right now. Prompting by feel, trusting your read of a diff, letting the
agent carry the boring parts: this is how a huge amount of real work gets done
today, mine included. I am not here to talk anyone out of it. I am here to talk
about what happens when you hit its ceiling, because I hit it hard, and the way
out turned out to be a ladder worth describing.

## The wall I hit

Here is the one that finally made me stop and think. I asked an agent to add
pagination to a list endpoint — ordinary `page` and `per_page` parameters,
nothing exotic. It came back fast: a clean handler, the new params wired
through, and a test. I read the diff. It was genuinely well-written. The test
passed. Looks good to me. Merged.

About a week later someone noticed the last page of results was sometimes empty,
and the reported total count was off by one — but *only* when the number of rows
divided evenly by the page size. A classic boundary bug. And here is the part
that stuck with me: the agent had written a test. The test used a list of
twenty-three items with a page size of ten. Twenty-three is not a multiple of
ten, so the exact boundary where the bug lived was never exercised. The test was
green because it tested the case that worked.

Nothing the agent claimed was false. The code did compile. The test did pass. It
*did* look good to me. The agent reported "done" and, by every check it had
chosen to run, it was done. The problem was that the one check that mattered
simply wasn't among the checks it ran — and "looks good to me" had no way to know
that.

I have since collected a small museum of these. The flaky test "fixed" by
loosening the assertion until it couldn't fail. The migration that ran clean on
an empty table and corrupted a populated one. The "handled the error" that
swallowed it into a log line nobody reads. Every one of them passed the same gate
I was using: my eyes, on a diff, deciding it looked fine.

## It is not the model

The tempting conclusion is "the model wasn't smart enough." I don't think that's
it, and I don't think a bigger model fixes it. A sharper agent writes a cleaner
boundary bug. The failure wasn't intelligence. It was that I had no definition of
"done" that lived anywhere outside the agent's own judgment and mine — and those
two judgments are correlated. We were both reading the same plausible diff and
both nodding at it.

Two things were missing, and naming them is the whole point of this series.

**There was no objective gate.** "Done" meant "the agent decided it was done and
I agreed." That is a gate made of two opinions. Nothing in the loop could
contradict us. The boundary case that broke had no representative in the room — no
check that would have turned red and forced the question. A definition of done
that can only be confirmed, never falsified, is not a definition of done. It is a
vibe.

**There was no durable structure.** Each session started cold. The agent
re-derived how this repo lays out tests, re-guessed our conventions, re-learned
what "we already decided not to do that" means — every time, because none of it
was written anywhere it could read. So the quality of any given run depended on
how much context I happened to paste that day. Good runs and bad runs, and no way
to tell which I was getting until something broke in production.

Those two gaps — *no objective gate* and *no durable structure* — are the ceiling
of "looks good to me." Not a flaw in the agent. A flaw in the setup around it.

## What you can do today

You do not need any new tool to take the first step, and I want this post to be
useful even if you read no further. Before your next agent task, write down — in
plain language, before any code exists — the conditions that must be objectively
true for the task to be done. Not "add pagination." Instead: *the last page
returns the remainder of rows; an exact multiple of the page size yields no empty
trailing page; the total count matches a direct `COUNT(*)`.* Three checkable
statements.

Now you have something the agent's "done" can be measured against that isn't just
your impression of a diff. Hand the agent those conditions up front. When it
reports done, run them — actually run them, don't read them — and treat any gap as
the agent's problem to close, not yours to wave through. You have just moved the
gate out of your head and into something that can say *no*.

It is a small move. It is also the seed of everything that follows, because once
"done" is a set of statements that can fail, a lot of other questions get sharper:
where do those statements live so you are not rewriting them every session? How
do you check ones that a unit test can't reach, like "it actually works in a real
browser" or "it is actually deployed"? How do you keep the agent from relitigating
a decision you already made three sessions ago?

## The limitation this leaves open

Here is the honest gap, and it is the reason there is a Part 2. A checklist you
hold in your own head, or paste in fresh each time, is still ephemeral. The next
session, the agent has forgotten your conventions again. The session after that,
*you* have forgotten which conditions mattered. You have an objective gate, but
it evaporates between runs, and the durable-structure problem is completely
untouched.

So the next rung is memory: giving the agent — and yourself — a place where the
context, the conventions, and the decisions persist across sessions, so each run
doesn't start from zero. That is where this series goes next.

This is Part 1 of a twelve-part ladder, from prompting by feel to a workflow
where "done" is something the system can prove rather than something you hope is
true. Each rung is a technique you can use on its own, with tools you already
have. You can start wherever you are standing. We are starting at the ceiling,
because that is where I started — looking at a clean diff, thinking *looks good to
me*, and being quietly, specifically wrong.

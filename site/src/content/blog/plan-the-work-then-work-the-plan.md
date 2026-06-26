---
title: "Plan the work, then work the plan"
description: "Your intent for the week lives in your head and a scatter of chat messages: a mental to-do list you re-derive every morning, with no shape you and the agent can both see. The next rung is making that intent an artifact — a plain checkable plan, each task tied to the outcome it enables and the tasks it depends on. Not a Gantt chart, just a Markdown file you and the agent work from and tick off together, so the work has edges instead of a vibe."
date: 2026-06-25
author: "kazi team"
tags:
  - vibe-coding
  - coding-agents
  - planning
  - series-from-vibe-coding-to-reconciliation
series: "From Vibe Coding to Reconciliation"
part: 7
draft: false
ogImage: /blog/art/part-07.svg
heroAlt: 'Header art for Part 7 of "From Vibe Coding to Reconciliation": Plan the work, then work the plan. A rung-7-of-12 position marker on the kazi gradient.'
---

Three days into a feature I thought was nearly finished, the agent asked me what
was left. I opened my mouth to answer and realized I did not actually know. I had
a feeling — "the API part is mostly done, there's some frontend, oh and the
migration" — but the feeling was a fog, not a list. I had been carrying the whole
plan in my head and in a trail of messages across four sessions, and the head is a
leaky place to keep a plan. I had finished things twice because I forgot they were
finished. I had skipped a step because nothing reminded me it existed. The work
was not hard; I just could not *see* it.

That is the wall this post is about. The previous six rungs gave "done" an
objective gate at the smallest scale, gave your project's knowledge a home, gave
the agent eyes on the running system, gave it a map of the code, and turned the
prompts you keep retyping into reusable skills. Skills made each individual *move*
reliable. But the *game* — the actual feature you are building this week, with its
many steps and their dependencies and its own idea of finished — is still an oral
tradition. It lives in your head and in scattered messages, exactly where the good
prompts used to live before you wrote them down. You made the instructions
durable. The intent is still a vibe.

## The wall I hit

An in-the-head plan fails in three specific ways, and that foggy week hit all
three.

The first is **you lose your place.** Without a written list, "what is left" is a
question you answer by reconstructing the whole project from memory every time you
sit down — and you reconstruct it wrong. You redo finished work because nothing
records that it is finished. You drop a step because nothing holds the slot for it.
Multiply that across a few sessions and a few interruptions and you are not
executing a plan, you are repeatedly guessing at one.

The second is **the agent cannot see the shape either.** When the plan is in your
head, every instruction you give the agent is a keyhole view of one task. It does
the task you named and has no idea it is task four of nine, that task seven cannot
start until this one lands, or that "done with the endpoint" is meaningless until
the migration it reads from exists. You are the only one holding the structure, so
you are the bottleneck for every decision about order and readiness — and you are
holding it in the leakiest possible place.

The third is **"what does done even mean here" is undefined per task.** A foggy
plan has foggy edges. "Add search" is not a task, it is a wish — does it include
the empty state, the typo tolerance, the loading spinner? When the scope of each
item lives only in your intention, you and the agent will disagree about whether an
item is finished, and you will not find out until much later that you meant
different things.

Same root cause for all three: intent is an *event*, not an *artifact*. It happens
in your head, in the moment, and it evaporates. This is the exact problem the last
post solved for prompts — and the fix turns out to be the same shape.

## The technique: make the plan an artifact

The fix is to take the plan out of your head and write it down as a file you and
the agent both work from. Not a project-management tool, not a Gantt chart, not
tickets with fourteen fields. A plain Markdown checklist in the repo is enough, and
because it is in the repo it travels, versions, and reviews like everything else.

The cheapest version is a list of checkboxes. But three small disciplines turn a
to-do list into a *plan*, and they are where the value is.

**One: each task is a checkable outcome, not an activity.** Write the task as the
observable result you want, specific enough that "is it done?" has a yes-or-no
answer, not an opinion. "Work on search" is an activity. "Typing a query filters
the list to matching rows; an empty query shows everything; no results shows the
empty state" is an outcome — three things you can actually look at and check. The
discipline is to phrase every line so that a stranger could tell whether it is
true. You will not always hit it, but reaching for it is what gives the task edges.

**Two: tie each task to the outcome it enables.** A plan is not just a pile of
work, it is work *in service of something*. Note, in a few words, what user-facing
capability each task unlocks — "so a user can find an old order." This sounds like
bookkeeping; it is actually a filter. Tasks that map to no outcome are how scope
creep gets in, and tasks whose outcome you cannot name are usually tasks you do not
understand yet. The mapping keeps the plan honest about *why*.

**Three: state dependencies out loud.** Write down which tasks must come before
which. "The search endpoint depends on the index migration." "The frontend filter
depends on the endpoint." You are not building a scheduler; you are just making the
order visible instead of carrying it in your head and rediscovering it the hard way
when the agent starts task seven and nothing it needs exists yet. Stated
dependencies also reveal what is *independent* — the tasks that have no edges
between them and could, in principle, be worked in any order. (Hold that thought;
it matters more than it looks, and a later post is entirely about it.)

Here is the whole thing, in a `PLAN.md` at the root of the repo:

```markdown
# Plan: order history search

- [ ] T1. Add a `created_at` index migration on `orders`.
      outcome: search can be fast enough to ship.  deps: none
- [ ] T2. `GET /orders/search?q=` returns orders matching the query.
      An empty `q` returns all; no matches returns `[]`, not an error.
      outcome: a user can find an old order by keyword.  deps: [T1]
- [ ] T3. Search box filters the visible list as you type; empty query
      shows everything; zero results shows the empty state.
      outcome: the user can actually use search in the UI.  deps: [T2]
- [ ] T4. A test asserts T2's three cases (match / empty / no-match).
      outcome: the endpoint stays correct as the code moves.  deps: [T2]
```

That is it. Four lines, but now the work has a shape. When the agent asks "what is
left," the answer is a file, not a guess. When I hand it a task, I hand it the
*context*: "Do T2 — here is its outcome and it depends on T1, which is done." When
I finish something I tick the box, and the act of ticking forces the question *is
this actually true?* against a written outcome instead of a feeling. The fog is
gone because the plan is outside my head, where I can look at it.

The deeper move here — and it is the quiet theme of this whole rung — is that
**writing the outcome down before you do the work is writing the acceptance check
before you do the work.** "Typing a query filters the list; empty shows everything;
no results shows the empty state" is not just a task description. It is the test
you will run to decide if the task is done. You have started, almost by accident,
to define "done" as something you can check rather than something you feel. Keep
that thread in mind. It is the one this series is climbing toward.

## How to try it today

You can do this in the next ten minutes with a text file.

1. **Make a `PLAN.md` in the repo and dump your head into it.** Everything you
   think is left, as rough bullets. Do not organize yet — just get it out of the
   fog and onto disk. You will immediately spot a thing you forgot and a thing you
   already finished.
2. **Rewrite each bullet as a checkable outcome.** Replace every "work on X" with
   the observable result that means X is done. If you cannot phrase it that way,
   that is a signal the task is still too vague to start — split it until each
   piece has a yes-or-no edge.
3. **Add an `outcome:` note and a `deps:` note to each.** What capability does it
   unlock, and what must come first. Two of these will surprise you: one task with
   no outcome (cut it or question it), and a dependency you would have tripped over.
4. **Work from the file, and tick boxes as you go.** Hand the agent one task at a
   time *with* its outcome and its satisfied dependencies. When you finish, check
   the box only if the written outcome is actually true — make the checkbox earn it.
5. **Edit the plan when reality teaches you something.** A plan is alive, like a
   skill. New task discovered mid-stream? Add it. Dependency you missed? Write it
   in. The plan is the running record of intent, not a contract you signed in blood
   on Monday.

The whole thing is harness-agnostic and tool-agnostic: it is a Markdown file. If
your setup has something fancier — an issue tracker, a planning tool your agent can
read — the same three disciplines apply there. The artifact is the point; the
format is plumbing.

## The limitation this leaves open

Here is the honest gap, and it is the reason there is a Part 8. A written plan
makes intent visible, ordered, and shared. It fixes *what to do* and *in what
order*. But look closely at the last step above: "check the box only if the
outcome is actually true." Who decides that it is true?

Right now, you do. You read the task, you glance at the result, you make a call,
you tick the box. And that call is exactly as trustworthy as "looks good to me" —
the very wall this whole series started at, one rung up. A checked box is a claim.
"I marked T2 done" is the same kind of statement as "the agent said it was done":
a human or an agent asserting that an outcome holds, with nothing forcing the
assertion to be true. The plan gave each task a checkable outcome — but nothing yet
*checks* it. The check is still a vibe wearing a checkbox.

So the next rung is the one this series has been circling since the first post:
turning that written outcome into a check that *runs* — a definition of "done" that
cannot lie because it is not an opinion, it is a result. A plan whose boxes tick
themselves, by something objective, only when the outcome is genuinely true. That
is where this series goes next, and it is the center of the whole climb.

This is Part 7 of a twelve-part ladder, from prompting by feel to a workflow where
"done" is something the system can prove rather than something you hope is true.
Each rung stands on its own. If you do only one thing from this post: before you
start your next feature, open a `PLAN.md`, and write each task as an outcome you
could check — not an activity you intend to do. The fog clears the moment the plan
leaves your head.

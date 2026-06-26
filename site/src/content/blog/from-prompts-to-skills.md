---
title: "From prompts to skills"
description: "You wrote a great prompt once — the careful instruction that made the agent do the thing right — and now you retype it every week, slightly differently, getting slightly different results. The next rung is codifying that prompt into a skill: a named, reusable procedure you invoke in one line instead of re-explaining from scratch. The compounding move from one-off cleverness to a workflow, with a concrete before and after you can copy today."
date: 2026-06-25
author: "kazi team"
tags:
  - vibe-coding
  - coding-agents
  - skills
  - prompting
  - series-from-vibe-coding-to-reconciliation
series: "From Vibe Coding to Reconciliation"
part: 6
draft: false
ogImage: /blog/art/part-06.svg
heroAlt: 'Header art for Part 6 of "From Vibe Coding to Reconciliation": From prompts to skills. A rung-6-of-12 position marker on the kazi gradient.'
---

Last week I typed, more or less, this paragraph for what must have been the tenth
time: "Before you rename this function, get the full caller list first. Then add
the new shape alongside the old one, make the old one delegate to it, migrate the
callers one file per commit and build after each, and only delete the old shape
once nothing points at it." It is a good paragraph. It is the careful refactor
procedure from the last post, and it works. The problem is that it lives nowhere
except in my fingers. Every time I need it I reconstruct it from memory, and every
reconstruction is a little different — last time I forgot to say "build after
each," and the agent batched all the migrations into one commit and broke the tree
in exactly the way the procedure exists to prevent.

That is the wall this post is about. The previous five rungs gave "done" an
objective gate, gave your project's knowledge a home, gave the agent eyes on the
running system, and gave it a map of the code so it stops re-reading the whole
repo. But the *good instructions you keep discovering* are still trapped in chat
history. You solve a class of problem well once, in a long careful prompt — and
then the next time that class shows up you start over with a blank box, half
remembering what worked, paying again for cleverness you already paid for.

## The wall I hit

The retyped-prompt problem has three costs, and I felt all of them before I had a
name for any of them.

The first is **drift**. A prompt you reconstruct from memory is never the same
twice. The version that worked had six steps in a specific order; the version you
type while distracted has five, and the missing one is load-bearing. You are not
running a procedure, you are improvising one, and the quality of your output
tracks how well you happened to remember today.

The second is **the blank-box tax**. Every recurring task starts cold. Writing
the good prompt the first time was real work — you thought about the failure
modes, the ordering, the edge cases. Retyping it is re-doing a fraction of that
thinking every single time, and it adds up to a surprising amount of a week.

The third is **it does not travel**. The teammate two desks over has hit the same
class of problem and written their own slightly-worse (or slightly-better) version
of the same prompt, in their own chat history, invisible to you. The knowledge
exists three times in the building and is shared zero times.

Same root cause for all three: a prompt is an *event*, not an *artifact*. It
happens once, in a conversation, and then it is gone. Anything valuable you put
into it evaporates the moment the session ends.

## The technique: codify the prompt into a skill

The fix is to take a prompt you have typed more than twice and turn it into a
**skill** — a named, written-down procedure your agent can load on demand. The
word "skill" sounds fancy; the commodity version is just *a file*. A skill is a
prompt that you (a) gave a name, (b) wrote down once, carefully, and (c) can
invoke in one line instead of retyping.

The cheapest possible version needs nothing but your editor: a markdown file in
your repo. Here is the refactor procedure from above, lifted out of my fingers and
into `prompts/safe-refactor.md`:

```markdown
# Skill: safe-refactor

When asked to change a widely-used function or symbol, do NOT edit it in place.
Follow this exact order and stop if any step goes red:

1. Get the full caller list first (find all references / call hierarchy).
   Report the count — that number is the plan.
2. Add the new shape alongside the old one. Build. Commit.
3. Make the old shape a one-line shim that delegates to the new one.
   Build — all existing callers still compile. Commit.
4. Migrate callers to the new shape, ONE file (or small cluster) per commit,
   building after each. Re-report the remaining caller count each time.
5. When the caller count hits zero, delete the shim. Build. Commit.

Never batch the migration into one commit. The build must be green after
every step.
```

That is the whole thing. Now, instead of reconstructing the paragraph, I say:
*"Apply the safe-refactor skill to `sendEmail`."* The agent reads the file and
runs the procedure I debugged once, the same way every time. The drift is gone
because the steps are written down. The blank-box tax is gone because I am
invoking, not re-deriving. And because it is a file in the repo, the teammate two
desks over can use it too — it travels.

**Before** (what I used to do — retype, every time, from memory):

> "Ok so before you rename this can you first find everywhere it's called... and
> then like, add the new version but keep the old one working, and move things
> over carefully, and build as you go so we don't break main..."

**After** (what I do now):

> "Apply the safe-refactor skill to `sendEmail`."

Both *mean* the same thing. Only one of them is reproducible.

A few things make a skill worth more than a snippet you paste:

- **It has a name and a trigger.** "safe-refactor" and "when asked to change a
  widely-used function" tell both you and the agent *when* to reach for it. The
  name is the handle you invoke; the trigger is when it applies.
- **It encodes the order and the guardrails, not just the goal.** The value is in
  "one file per commit, build after each, stop if red" — the hard-won details you
  would forget. A skill is where your failure modes go to be remembered.
- **It is versioned with the code.** Because it is a file in the repo, it changes
  through the same review as everything else. When you learn the procedure needs a
  new step, you edit the file once and everyone's next invocation gets the fix.

This is harness-agnostic on purpose. Many coding agents now have a first-class
version of this — saved prompts, custom slash-commands, or a dedicated "skills"
folder the agent auto-loads — and if yours does, use it; it gets you invocation by
name and sometimes automatic triggering. But none of that is required. A markdown
file you reference, a text-expander snippet, even a `Makefile` target that pipes a
template into the agent — all of them turn the event into an artifact. The
*technique* is "name it, write it down once, invoke it by reference." The specific
mechanism is just plumbing.

## How to try it today

You almost certainly already have a skill waiting to be extracted. Find it and
file it:

1. **Catch yourself retyping.** The next time you start a prompt with "ok so like
   last time I had you..." — stop. That sentence is the tell. The thing you are
   about to reconstruct is a skill that does not exist yet.
2. **Write the good version once, carefully.** Not the rushed version — the one
   with the ordering and the guardrails spelled out. Steal from your own best past
   session if you can find it in the history. Give it a name and a one-line "use
   this when..." trigger at the top.
3. **Put it where it is loadable.** A `prompts/` or `skills/` folder in the repo is
   the zero-dependency choice; if your agent has a native skills/commands feature,
   put it there instead so you can invoke it by name.
4. **Invoke it by reference, not by paste.** "Apply the safe-refactor skill to X."
   The point is that the procedure lives in the file, not the message — so the file
   is the one place you improve it.
5. **Edit the file when reality teaches you something.** A skill is alive. When a
   run reveals a missing step, add it to the file, not to your memory. That is the
   compounding: every painful lesson becomes a permanent part of the procedure
   instead of something you relearn.

One small bonus once skills are just files: you can *read other people's*. A good
skill someone else wrote and shared is a procedure you get for free — drop it in
your folder and invoke it. (Borrow deliberately, the same way you would any
dependency: read it before you run it.) That is not a separate rung, just a nice
consequence of the artifacts being portable.

## The limitation this leaves open

Here is the honest gap, and it is the reason there is a Part 7. A skill is a
fantastic answer to *how* to do a recurring task — it captures a procedure and
makes it repeatable. But a skill knows nothing about *what you are trying to
accomplish right now*. "safe-refactor" will faithfully run its five steps the
moment you invoke it, but it cannot tell you that the refactor is one of nine
things this feature needs, that three of them depend on each other, or that you
finished six and lost track of which. Skills make each *move* reliable; they say
nothing about the *game*.

So the work itself — the actual thing you are building this week, with its many
steps and their dependencies and its own definition of finished — is still living
where the prompts used to live: in your head and in scattered messages. You have
made the individual instructions durable. The *intent* is still an oral to-do
list. The next rung is making that intent an artifact too: a written, checkable
plan, with tasks tied to outcomes and dependencies stated out loud, so the work
has a shape you and the agent can both see and track. That is where this series
goes next.

This is Part 6 of a twelve-part ladder, from prompting by feel to a workflow where
"done" is something the system can prove rather than something you hope is true.
Each rung stands on its own. If you do only one thing from this post: the next
time you catch yourself retyping a prompt you have written before, stop, write the
good version down once with a name, and invoke it by reference from now on. You
will never reconstruct it from memory again.

---
title: "The pattern underneath: reconciliation"
description: "Nine rungs in, the techniques start to rhyme. Memory, eyes, a written plan, an objective \"done,\" parallel agents that recover — each one turned out to be the same small loop wearing a different hat: declare the state you want, drive an agent toward it, check the result against reality, and go around again until it holds or you stop honestly. This post names that loop. It is a borrowed idea — the control loop behind CI and behind Kubernetes — pointed at coding goals, and its one rule is that the truth about \"done\" lives in the controller, never in the thing being driven."
date: 2026-06-25
author: "kazi team"
tags:
  - vibe-coding
  - coding-agents
  - reconciliation
  - series-from-vibe-coding-to-reconciliation
series: "From Vibe Coding to Reconciliation"
part: 10
draft: false
ogImage: /blog/art/part-10.svg
heroAlt: 'Header art for Part 10 of "From Vibe Coding to Reconciliation": The pattern underneath: reconciliation. A rung-10-of-12 position marker on the kazi gradient.'
---

Somewhere around the ninth rung I stopped feeling clever and started feeling
like I was repeating myself. I had a memory file so my agent stopped re-learning
the repo. I had a way to make it look at the running app instead of trusting its
own diff. I had a written plan with checkable outcomes, a definition of "done"
that could come back red, and a way to run several agents at once without them
trampling each other. Nine different problems, nine different fixes, each earned
the hard way. And yet every time I set one of them up, I was typing the same
shape of sentence to myself: *here is what should be true; go make it true; let
me check; not yet, go again.*

That nagging repetition is the subject of this post. The nine rungs are not nine
unrelated tricks. They are nine instances of one loop I had been hand-rolling
without naming. This is where I name it.

## The wall I hit: I was the control loop

Here is the moment it landed. I was running three agents in parallel — the setup
from the last rung — and I caught myself doing, by hand and in my head, the exact
same job for each one. For agent A: *the order-search endpoint should exist and
be wired and safe; go build it; let me probe it; the adversary found injection,
not done, go again.* For agent B, the same shape with different nouns. For agent
C, again. I was a human `while` loop, three iterations deep, re-improvising the
condition every lap and keeping the whole thing alive on pure attention.

And it was not just those three. I scrolled back up the ladder and the same shape
was everywhere. The memory file from Part 2? That is me declaring "the agent
should know these conventions," then checking each session whether it actually
did, and amending the file when it didn't — a loop with a slow clock. The browser
verification from Part 4: declare "the live page works," observe reality, fix the
gap. The plan from Part 7: declare outcomes as checkable boxes. The objective
"done" from Part 8: a check that has the authority to say *not yet*. Every rung
was the same four moves. **Declare the desired state. Drive toward it. Check
against reality. Repeat until it holds or you stop honestly.**

The wall, then, was not a missing technique. I had plenty of techniques. The wall
was that I was the thing running them — the scheduler, the checker, the retry
logic — and I do not scale, I get tired, and I forget which lap I am on. The loop
was real and load-bearing. It just had no home outside my head.

## The technique: name the loop, and borrow it

The good news is that this loop is not new, and I did not have to invent how it
should behave. It is one of the most battle-tested ideas in operations, and it
already runs two systems most developers touch every day.

The first is **continuous integration**. CI is a control loop with a brutally
simple contract: you declare what "good" means as a suite of checks, every change
is driven against them, and the build is green or red — not "the author thinks it
is fine." The verdict does not live with the person who wrote the code. It lives
in the pipeline. That is the whole reason CI works: it moved the definition of
"passing" out of the author's opinion and into a checker the author cannot just
assert their way past. That is exactly the move Part 8 made for "done."

The second, and the one that names the full shape, is **reconciliation** in the
Kubernetes sense. You hand the system a declared *desired state* — "I want three
replicas of this service running" — and a controller runs a loop forever:
observe the actual state of the world, diff it against what you declared, take an
action to close the gap, observe again. You never tell it the steps. A pod dies;
the controller notices the gap between desired (three) and actual (two) and starts
one. The cluster's truth about what should be running lives in the controller and
its declared spec, not in any individual pod's belief about itself. A pod cannot
vote itself healthy. The loop decides, against reality.

Lay that template over the nine rungs and they snap into place, because each rung
was supplying one organ of the same controller:

- **Desired state** — the declaration of what "done" looks like. The memory file
  and conventions (Part 2), the homed decisions (Part 3), and above all the
  written, checkable plan (Part 7) are how you write the spec down so it persists
  and an agent can read it.
- **Drive** — the coding agent doing the work, on each lap. The skill you
  codified (Part 6) is just a reusable way to drive a step the same way twice.
- **Observe against reality** — giving the agent eyes all the way to prod (Part 4)
  and the code graph that shows real callers and blast radius (Part 5). This is
  the *actual* state, measured, not assumed.
- **Diff and decide** — the objective "done" with the authority to come back red,
  adversary included (Part 8). This is the controller's verdict: gap or no gap.
- **Repeat, in parallel, and survive interruptions** — running many of these loops
  at once on isolated worktrees and resumable state (Part 9).

The borrowed frame is the point, not a flourish. A brand-new category is expensive
to explain; a borrowed one is graspable in a line. The category these rungs add up
to is the one this series has been walking toward —
**the outer/reconciliation loop for coding agents**, or in the shorter borrowed
form, **Kubernetes for coding goals**. CI moved the verdict on a *change* off the
author. Kubernetes runs a
*loop* that closes the gap to a declared state, forever, against reality. Point
both at a coding goal and you get the thing underneath all nine rungs: declare the
goal as something checkable, drive an agent at it, let a controller — not the agent
— decide whether reality matches, and go around until it does, it gets stuck, or it
runs out of budget.

The one rule that makes it work is the same rule that makes CI and Kubernetes
work: **the truth lives in the controller.** Not in the agent's "done," not in the
diff that reads clean, not in your own tired read at 6pm. The thing driving the
work never gets to be the thing that grades it. Every rung in this series was, in
hindsight, a way of moving one more piece of the verdict out of the agent's mouth
and into a loop that checks against the world.

## It generalizes: the loop runs on your own work too

Here is the part that surprised me, and it ties two earlier rungs together. The
loop is not just for the running *system*. It is just as true of your own
*work-in-progress* — the half-finished task itself.

Think about what a checkpoint actually is. Back in Part 2, the persistent-memory
rung, the quiet move was writing down the desired end-state of a piece of work so
that a fresh session — or a fresh agent — could read it and pick up where the last
one left off. That is reconciliation applied to your *intent*: declare where this
is supposed to end up, and on any interruption, observe what is actually done so
far, diff it against the goal, and drive the remainder. The "resume without
redoing" discipline from Part 9 is the same loop with the clock stopped and
restarted: when a parallel run halts, you do not start over, you read the real
state from git, diff it against the declared backlog, and drive only the gap. Part
2 wrote the desired state down so it would survive; Part 9 read the actual state
back so recovery was a diff, not a redo. Those are the two halves of one
reconciliation loop wrapped around the work itself.

A stuck deployment is the cleanest example. When a release will not roll out, the
honest move is not to poke at it by feel — it is to reconcile the deploy stack:
the desired state is "the new version is serving traffic," the actual state is
whatever the pipeline, the rollout, and the pods actually report, and you walk the
gap layer by layer until declared and actual agree. That is the same loop you run
on a feature, pointed at the infrastructure. Once you have the shape, you start
seeing it everywhere: anything you can declare a desired end-state for, observe
honestly, and drive toward in laps is a reconciliation problem in disguise.

## How to try it today

You do not need anything new to feel this — you need to re-read the nine rungs as
one pattern and run it deliberately on your next task:

1. **Write the desired state down first, as something checkable.** Not "make the
   search better" but the three things that must be objectively true when it is
   done. This is your spec; it is the part most people skip.
2. **Drive, don't dictate.** Hand the agent the goal and let it take a lap. You
   are setting the desired state, not narrating every step.
3. **Observe against reality, not against the diff.** Probe the running thing.
   Reality is the actual state; the agent's summary is a claim about it.
4. **Diff, and let the verdict be allowed to say "not yet."** If the gap is real,
   the work is not done — go around again. The controller decides, not the driver.
5. **Stop honestly.** A real loop has exits other than success: it converges, or
   it gets stuck, or it runs out of budget — and it says which, out loud, rather
   than declaring victory by default.

Run that on one task by hand and you will feel exactly what I felt at rung nine:
that you are the control loop, and that the loop wants a home that is not you.

## The limitation this leaves open

So that is the pattern underneath the whole ladder. Memory, eyes, decisions, a
code graph, skills, a plan, an objective "done," parallel agents — nine rungs, one
loop: declare the desired state, drive an agent toward it, check against reality,
repeat until it holds or you stop honestly, with the verdict living in the
controller and never in the thing being driven. Naming it changed how I see every
rung below it. They were never a grab-bag of tips. They were me assembling a
reconciliation controller out of commodity parts, one organ at a time.

But naming the loop is not the same as having it. Right now *I* am still the
controller. I hold the desired state in my head, I drive each lap, I run the diff,
I decide whether to go again — across several agents at once, by hand, every
session. The pattern is clear; the *automation* of it is not. Everything in this
series so far has been a technique you assemble yourself, and assembling a control
loop by hand, lap after lap, is exactly the kind of work a control loop is
supposed to do for you.

A tool that packages rungs seven through ten into an actual controller — one you
hand a declared goal and it runs the loop so you do not have to — is the obvious
next step. That tool exists, and the next post is where it finally has a name.

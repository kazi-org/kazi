---
title: 'Meet kazi: "done," proven'
description: "Ten rungs of this series assembled a control loop out of commodity parts: a memory file, eyes on prod, a written plan, an objective \"done,\" parallel agents that recover. The last post named the loop and then admitted the obvious gap — I was still running it by hand, lap after lap. This post introduces the tool that packages those rungs into an actual controller. You declare a goal as machine-checkable predicates, your agent drives kazi, and it converges or it stops honestly: stuck, or over budget. No new magic — just the loop you already built, with a home that is not your attention. Strictly what it does today."
date: 2026-06-25
author: "kazi team"
tags:
  - vibe-coding
  - coding-agents
  - reconciliation
  - kazi
  - series-from-vibe-coding-to-reconciliation
series: "From Vibe Coding to Reconciliation"
part: 11
draft: false
ogImage: /blog/art/part-11.svg
heroAlt: 'Header art for Part 11 of "From Vibe Coding to Reconciliation": Meet kazi: "done," proven. A rung-11-of-12 position marker on the kazi gradient.'
---

The last post ended with a confession. I had finally named the loop underneath
all nine rungs — declare the desired state, drive an agent toward it, check
against reality, repeat until it holds or you stop honestly — and in the same
breath I had to admit that *I* was still the thing running it. I held the desired
state in my head. I drove each lap. I ran the diff. I decided whether to go
again, across several agents at once, every session, on pure attention. The
pattern was clear. The automation of it was not.

This is the post where the automation gets a name. After ten rungs of assembling
a control loop by hand out of commodity parts, here is the tool that packages the
top of that ladder into an actual controller you can hand a goal to. It is called
**kazi**, and the one-line version of what it does is the line on its home page:

> Your coding agent says "done." kazi proves it.

Everything below is strictly what kazi does today. Where something is still
coming, I say so.

## The wall I hit: being the controller does not scale

Naming a loop and *being* a loop are different jobs, and the second one wears you
down. Here is the shape of the wall, concretely.

I would set a piece of work in motion — "the order-search endpoint should exist,
be wired, be covered, and return 200 against the real deploy" — and then I became
the runtime for it. Lap one: the agent says it is done; I read the diff, it looks
plausible, I probe the running thing, the endpoint 500s. Not done. Lap two: fixed
the 500, but the test I asked for never got written. Not done. Lap three: tests
pass, but the adversary pass from Part 8 finds an injection. Not done. Each lap I
am re-deciding, by hand, what "done" even means for this task and whether the
latest attempt cleared it. Multiply that by three agents running at once and I am
a `while` loop with no memory of which iteration I am on, kept alive by coffee.

The techniques were all there. Memory, eyes, a plan, an objective gate, parallel
recovery — I had every organ of the controller from Parts 2 through 9. What I did
not have was a *controller*: a thing that holds the desired state, drives the
agent, runs the check, and decides whether to go around again, so that I do not
have to be awake for every lap. The verdict still lived in my tired read at 6pm,
which is exactly the place Part 8 said the verdict must never live.

## What kazi is: the loop, packaged

kazi is **the outer/reconciliation loop for coding agents**. That is the whole
positioning, and it is the same loop this series has been climbing toward, now
running as software instead of in your head.

The mechanism is the one from Part 7 and Part 8, made literal. You declare a goal
as a set of **predicates** — machine-checkable statements that must be true for
the work to count as done. A predicate is something like "the unit tests pass,"
"the integration suite is green," "the deployed endpoint returns 200," or a guard
like "test count does not drop." Each predicate is evaluated by a provider that
returns pass or fail *with stored evidence* — not an opinion, a recorded check.
The goal also carries a **budget** (a hard ceiling on iterations, tokens, or
wall-clock) and a **scope** (the paths the agent may touch).

Then kazi runs the loop you were running by hand:

- **observe** — evaluate every predicate and attach evidence;
- **diff** — the failing predicates *are* the work list;
- **dispatch** — drive your coding agent at the failing predicates;
- **re-observe** — evaluate again, and compare the new result vector to the last;
- **decide** — and this is the part that matters.

The decision has exactly three terminal outcomes, and naming them honestly is the
entire point of the product:

- **`converged`** — every predicate is true, with evidence. This is the only way
  the loop is allowed to declare success. There is no "the agent thinks it's
  done"; done is *all predicates true*, full stop.
- **`stuck`** — the same predicates keep failing lap after lap with no progress.
  Rather than burn your budget pretending, kazi stops and tells you it is stuck.
- **`over_budget`** — the ceiling was reached before convergence. It stops and
  says so.

That is the without/with frame this series has been building to, stated plainly.
*Without* kazi: your agent stops when it *believes* it is finished, and you are
the one who finds out later that "believes" and "is" diverged. *With* kazi: the
loop can only stop as `converged` when an objective gate says every predicate is
true against reality — and when it cannot get there, it says `stuck` or
`over_budget` out loud instead of declaring a hollow victory. The truth about
"done" lives in the controller, never in the agent being driven. That is the one
rule from Part 10, now enforced by a program.

The reason this needs a controller and not just a longer checklist is the set of
ways a hand-run loop quietly goes wrong, each of which kazi handles on your
behalf. It tracks the full predicate *vector* across laps, so a fix that turns
predicate A green while breaking predicate B is caught as a regression instead of
counted as progress. It supports re-running or quarantining a flaky predicate, so
one nondeterministic failure does not poison the loop into grinding forever. And
the guard predicates — "test count must not drop," "coverage must not regress" —
block the oldest shortcut in the book, deleting the failing test to turn the build
green. These are precisely the failure modes you stop being able to police by hand
the moment more than one agent is running, and they are the hard parts the
controller exists to own.

A few honest boundaries on what that means today. kazi does not write your code —
it drives whatever coding agent you already use (the default is Claude Code; it
can drive others). It does not invent your definition of done — *you* declare the
predicates, kazi just refuses to let them be faked. And it is harness-agnostic by
design: the story here is told through Claude Code for concreteness, but the
controller sits *above* the harness, so the same goal can be driven by a
different agent.

## How to try it today

You do not run kazi yourself. That is deliberate, and it is the most important
thing to understand about how it is wired. The adoption spine is:

> you → Claude Code → kazi → Claude Code.

You keep chatting with your coding agent the way you already do. kazi works
behind it. The one-time setup teaches your agent a skill that knows how to drive
kazi for you.

Install it (Homebrew tap):

```sh
brew install kazi-org/tap/kazi
```

Then, once, teach your agent the recipe:

```sh
kazi install-skill
```

That writes a Claude Code skill — opt-in, nothing else touches your agent's
config — whose entire job is to drive kazi's two verbs for you. From then on, you
work in two moves, in plain Claude Code:

```text
/kazi plan "add a /healthz endpoint that returns 200 ok, with a test, deployed"
/kazi apply
```

`/kazi plan` has your agent author the acceptance predicates from your prose idea;
you glance at them and approve. `/kazi apply` then runs the reconcile loop until
every predicate is objectively true — or it reports `stuck` or `over_budget`. You
do not even have to remember the two verbs. The skill's trigger is the plain
sentence:

> have kazi drive this until done

Say that, and the skill runs the same `/kazi plan` → `/kazi apply` for you and
reports the result back in your chat. You never leave the conversation with your
agent.

Here is an *illustrative* shape of one of those sessions. (It is illustrative, not
a recorded run — a recorded cast of a real convergence loop is **coming** as a
series asset; this sketch uses only the verbs and outcomes kazi ships today, so it
will not drift.)

```text
> have kazi drive this until done: a /healthz endpoint that returns 200,
  with a test, deployed and confirmed live

# the skill drafts predicates, you approve, then it drives the loop:
/kazi plan "..."     # author acceptance predicates from the idea, then approve
/kazi apply          # observe → dispatch → re-observe → decide, each lap

# lap 1: endpoint missing, test missing            → keep going
# lap 2: endpoint added, returns 500 against prod   → keep going
# lap 3: fixed; unit + live-probe predicates green  → converged

outcome: converged — every predicate true, with evidence.
```

If instead the same failing predicates persisted with no progress, the last line
would read `outcome: stuck`; if the budget ran out first, `outcome: over_budget`.
The loop always tells you which of the three happened — that honesty *is* the
feature.

Two more verbs are worth knowing, because they make the plan step reviewable
rather than a black box. `kazi list-proposed` shows the queue of drafted goals
awaiting your approval, `kazi approve` (or `kazi reject`) moves one through its
gate, and `kazi status` reports a run or proposal's current state from the
read-model — a pure read you can check any time. Every command and state named in
this post is one kazi ships today; you can confirm the full surface yourself with
`kazi help --json`.

## The limitation this leaves open

So the loop finally has a home that is not my attention. I declare the goal as
predicates, my agent drives kazi, and it converges or it stops and tells me why.
The thing I was doing by hand at rung ten — holding the desired state, driving
each lap, running the diff, deciding whether to go again — is now a controller's
job, and the verdict lives where Part 8 and Part 10 said it had to: in the gate,
not in the agent.

But knowing a tool *exists* is not the same as having it wired into your day, and
this post deliberately stopped short of the full on-ramp. I showed you the two
verbs and the invocation phrase, but I did not walk the rest of the wiring — how
you go from a fresh `brew install` to letting an agent drive kazi against a real
goal with confidence, where you can start if you have only climbed three of these
rungs, and the honest "here is where it is going next" that any tool you are
asked to trust owes you.

There is also a question this whole series has been circling and not quite asked:
before you let an agent run a loop *unsupervised* — converging against your real
repo, lap after lap, while you are not watching — do you actually trust the
harness you are handing the keys to? That is its own piece of work, and it belongs
in the close.

That close is Part 12: your on-ramp. A recap of the whole ladder, the copy-paste
wiring to drive kazi from your agent, how to harden your harness before you let it
run unattended, an honest roadmap with no vaporware, and a respectful invitation
to try it on something real. We named the loop, then we packaged it. Next we hand
you the keys.

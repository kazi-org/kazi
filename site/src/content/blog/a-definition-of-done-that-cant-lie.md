---
title: "A definition of \"done\" that can't lie"
description: "Your agent says \"done — tests pass, everything works,\" and most of the time it is telling the truth as it understands it. That is the problem. A self-report is an opinion, and an opinion can only ever come back green. The next rung is giving \"done\" a definition that has the authority to come back red: tests it did not grade itself on, a wiring check, a live probe against reality, and an adversary actively trying to break it. Truth about whether the work is finished has to live somewhere the agent cannot simply assert it into being."
date: 2026-06-25
author: "kazi team"
tags:
  - vibe-coding
  - coding-agents
  - testing
  - series-from-vibe-coding-to-reconciliation
series: "From Vibe Coding to Reconciliation"
part: 8
draft: false
ogImage: /blog/art/part-08.svg
heroAlt: 'Header art for Part 8 of "From Vibe Coding to Reconciliation": A definition of "done" that can''t lie. A rung-8-of-12 position marker on the kazi gradient.'
---

The message came back with its usual small flourish of confidence: "Done — I've
added the order-search endpoint, the tests pass, and everything is working." I
read it, skimmed the diff, saw a tidy new route and a fresh test file, nodded,
and moved on. The feature shipped that afternoon. It looked good to me, and for
once I had even checked.

Nine days later a support ticket landed: a customer had typed a stray quote into
the search box and gotten back a page of orders that were not theirs. The endpoint
built its SQL by pasting the raw query string into a `LIKE` clause, so a quote
closed the string early and the rest of the input ran as logic. "The tests pass,
everything is working" had been completely true and completely meaningless.

That is the wall this post is about, and it is the one the whole series has been
walking toward. Every rung so far made the agent more capable and the work more
visible: it remembered the repo, it had a home for decisions, it could see the
running app, it had a map of the code, it worked from a written plan with checkable
outcomes. But the last rung ended on an uncomfortable question. The plan said
"check the box only if the outcome is true." Who decides it is true? Right now, the
agent says so, and you nod. The checked box and the agent's "done" are the same
kind of statement: a claim, with nothing forcing it to be honest.

## The wall I hit: an opinion can't fail

Here is the uncomfortable part of "the tests pass, everything is working" — it was
not a lie. The agent was reporting, accurately, that the checks it knew about were
green. The trouble is where those checks came from. The agent wrote the feature,
and the agent wrote the tests, and the tests asserted exactly the behavior the
agent set out to build. It tested that a normal query returns matching orders. It
did not test an empty query, a query with a quote in it, or whether the results
were scoped to the logged-in user — because none of those were in its mental model
of the task. A check written by the same author to confirm their own intent can
only ever come back green. It is a mirror, not a gate.

This is the precise, falsifiable claim at the center of this post: **the agent's
self-report has no power to say no.** A real gate is defined by the fact that it
*can* fail — it has the authority to come back red and stop the work. "Done,
everything works" has no such authority. It is structurally incapable of returning
red, because the thing producing the verdict and the thing being judged are the
same thing. You can test this yourself in thirty seconds: ask your agent to build
something, let it declare victory, then hand the exact same diff to a *second*
fresh agent and ask "what is wrong with this?" The second one, with no ego in the
work, will find things in a minute. The opinion didn't change; only the incentive
to be honest did.

So "looks good to me" — the wall this series opened on — is not a beginner's
mistake you grow out of. It is what you get *by default* whenever the verdict on
the work comes from the same place as the work. Plans, memory, eyes, and skills all
made the work better. None of them moved the *verdict* out of the agent's own mouth.

## The technique: a "done" that can come back red

The fix is to define "done" as a set of checks the agent does not get to grade
itself on — checks that have the standing to fail. None of this is exotic; it is
ordinary engineering discipline, pointed deliberately at the agent's blind spot.
Think of it as four layers, each of which can independently turn the verdict red.

**1. Tests it did not write to flatter itself.** The agent's own happy-path test is
fine, but the gate is the tests *you* specify from the outcome — the empty input,
the malformed input, the boundary, the "what if this is someone else's data."
Going back to my search bug: the outcome was "a user finds *their* orders by
keyword." The checks that fall out of that sentence — empty query returns
everything, no match returns an empty list not a 500, and results are scoped to the
current user — are exactly the three the agent skipped. Written down first, they
are a gate. Written by the agent after the fact, they are a mirror.

**2. A wiring check.** "The function exists and passes its test" is not "the
function is reachable." Agents routinely build a correct component that nothing
calls — a route never registered, a handler never mounted, a config never read. The
check is dumb and effective: from the outside, exercise the path a real user takes
and confirm it actually hits the new code. If the only thing that calls your new
endpoint is its unit test, it is not wired; it is decoration.

**3. A live probe.** Green in CI proves the code compiles and its tests pass. It
does not prove the thing serves traffic. The cheapest honest check is to hit the
real, deployed surface once — `curl` the endpoint, click the button in a browser
against the live URL, watch one real invocation in the logs — and confirm reality
agrees with the test. This is the rung from "Give your agent eyes," pointed at the
definition of done: the verdict comes from the running system, not from a belief
about it.

**4. An adversary.** This is the layer most people skip, and it is the one that
caught my bug. Part of an honest "done" is someone actively *trying to break the
work* — not reviewing it for style, attacking it. Two passes, and the important
word for both is **scored**, not "looks fine."

The first pass is a security / red-team review: feed the input the agent would
never feed itself. Injection (a quote, a semicolon, a `../`), auth boundaries (ask
for resource 124 while logged in as the owner of 123), and invariant violations
(can a balance go negative? can an order belong to two users?). The second pass is
a deep review that traces the actual code paths rather than skimming the diff. The
output is not a vibe — it is a count: *N findings at this severity*, and the gate
is a number, e.g. "zero high-or-critical findings," which can plainly come back red.

Concretely, here is what that adversarial pass produced on my "finished" search
endpoint — the kind of finding, not a buzzword list:

```
finding (HIGH): SQL injection in GET /orders/search
  the q param is concatenated into the query:
      "... WHERE customer LIKE '%" <> q <> "%'"
  proof: q = `' OR '1'='1` returns ALL orders, ignoring the filter
  fix: parameterize — pass q as a bound parameter, never string-built

finding (HIGH): missing tenant scope on GET /orders/search
  results are not filtered by the current user; order ids from another
  account are returned when their text matches
  proof: as user A, search a term only in user B's orders -> B's rows returned
  fix: add `where user_id == ^current_user.id` to the base query

score: 2 high  -> GATE: RED (threshold: 0 high/critical)
```

That is what "a definition of done that can't lie" looks like in practice: a
verdict that came back **red** on work the author sincerely believed was green —
with a reproduction line for each finding, so the verdict is checkable rather than
a matter of trust. The agent's opinion said done. The gate said no, twice, with
proof. The gate wins, because the gate is the only one of the two that was capable
of saying no at all.

## How to try it today

You can build a modest version of this with tools you already have, on your next
feature, harness or no harness.

1. **Write the checks from the outcome, before the build.** Take the task's
   one-sentence outcome and turn it into the three or four things that must be true
   — including the empty case, the malformed case, and the "is this scoped to the
   right user/tenant" case. These are your gate. Hand them to the agent as the
   target, not as an afterthought.
2. **Make the build prove it is wired.** Don't accept "the test passes" — require
   one check that exercises the feature from the outside (an end-to-end test, a
   `curl`, a click) and lands in the new code. If nothing but a unit test reaches
   it, it isn't done.
3. **Probe reality once.** Before you call it shipped, hit the real deployed
   surface a single time and confirm it behaves. One live observation beats a
   thousand green CI checkmarks for the question "does it actually work."
4. **Run an adversary, and score it.** Open a *second*, fresh agent session with an
   explicitly hostile prompt: "Here is a diff. Find injection, auth-boundary
   bypasses, and broken invariants. For each, give a one-line reproduction and a
   severity." Pair it with a commodity static scanner (an open-source SAST tool, a
   linter's security rules, a dependency audit) so it is not all one model's
   judgment. Treat the result as a number — N high findings — and refuse to ship on
   anything above your threshold. (A security-review or deep-review *skill*, the
   rung from "From prompts to skills," is just a way to make this pass repeatable;
   the portable technique is the adversarial second pass itself.)
5. **Let the gate be allowed to say no.** The whole point collapses if a red result
   is something you talk yourself past. If the adversary finds a HIGH, the work is
   not done — full stop. A gate you override on a feeling is just an opinion with
   extra steps.

None of this requires a special tool. A second agent with a hostile prompt, a
handful of tests you wrote from the outcome, one `curl` against prod, and an
open-source scanner will move your "done" from a claim to a check today. The
techniques are commodity; what changes is *who holds the verdict.*

## The limitation this leaves open

So now "done" can come back red. The verdict no longer lives in the agent's mouth;
it lives in a set of checks with the authority to fail, and you have an adversary
whose whole job is to make them fail. This is the rung the whole series was
climbing toward, and it is worth sitting with: you can now drive a coding agent and
*trust the stopping condition*, because the stopping condition is not its opinion.

An objective gate like this, packaged so an agent drives toward it in a loop until
the checks pass or it stops honestly, is roughly what kazi is: you declare "done"
as predicates and `kazi apply` runs the agent against them until they are true,
stuck, or out of budget — the verdict comes from the gate, never the agent. That is
the one time I will name it; the technique above stands entirely on its own without
it.

But here is the honest gap. Everything above assumes *one* developer driving *one*
agent through *one* gate at a time. The moment the work is real — a backlog of tasks,
some independent, some not — you will want more than one agent running at once, and
you will discover that two agents converging on two "done" gates in the same repo
will happily edit the same files, clobber each other's work, and leave you
reconciling a mess that neither gate caught because each one passed in isolation.
An objective definition of done makes a single stream of work trustworthy. It does
nothing, on its own, to keep several streams from colliding.

That is Part 9: one developer, many agents — how to run them in parallel without
their stepping on each other, and how to recover when one of them falls over
mid-flight. We have made "done" honest. Next we make it *scale*.

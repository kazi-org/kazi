---
title: "Give your agent eyes (all the way to prod)"
description: "Green tests and a clean diff prove the code compiles, not that it works. The next rung is verification that reaches reality: drive a real browser, exercise the change live, and carry it all the way through a release pipeline to a running production — so 'done' means 'I watched it work where users will,' not 'the agent said so.'"
date: 2026-06-25
author: "kazi team"
tags:
  - vibe-coding
  - coding-agents
  - verification
  - series-from-vibe-coding-to-reconciliation
series: "From Vibe Coding to Reconciliation"
part: 4
draft: false
ogImage: /blog/art/part-04.svg
heroAlt: 'Header art for Part 4 of "From Vibe Coding to Reconciliation": Give your agent eyes (all the way to prod). A rung-4-of-12 position marker on the kazi gradient.'
---

The agent said it added a "copy link" button to the share dialog. The diff was
clean, the unit test asserted the click handler called the clipboard API, and the
test was green. I merged it. Two days later someone asked why the button did
nothing. It turned out the dialog rendered the button behind a transparent
overlay that swallowed every click. The handler was perfect. It was just
unreachable by a human with a mouse — and nothing in the test suite had a mouse.

That is the wall this post is about, and it is a different wall than the last
three. Parts 1 through 3 were about giving "done" an objective gate and giving
your project's knowledge a durable home. But every check we built lived in
*words and unit tests*. A unit test confirms a function returns what you told it
to return. It has no eyes. It cannot see that the button is behind an overlay,
that the page renders blank on a slow connection, or — the one that really
stings — that the change you merged is not actually deployed and the URL your
users hit is still serving last week's code.

## The wall I hit

I hit it twice in the same week, at opposite ends of the pipeline, and together
they taught me the same lesson.

The first was the buried button above. Green locally, broken in a browser. The
gap between "the function works" and "a person can use the feature" is enormous,
and a unit test sits entirely on the wrong side of it.

The second was worse because it was invisible. I shipped a fix for a
rate-limiting bug, watched the pull request merge, watched continuous
integration go green, and told the person who reported it that it was handled.
It was not handled. The merge had built an artifact, but the deploy step had
failed silently — a permissions error three layers down that never surfaced as a
red X anywhere I was looking. The code was correct. It was correct in a registry
nobody was serving from. For a full day "done" meant "merged," and "merged"
meant nothing to the user still getting throttled.

Same root cause both times: I was treating a *claim about the code* as evidence
about *reality*. "The test passed" is a claim. "It merged" is a claim. Neither
one is a person clicking the button on the live site and watching it copy the
link. I had no check anywhere that observed the running system instead of the
agent's belief about it.

## The technique: verify against reality, not against the claim

The fix is to add a class of check that *looks at the running thing* — and to
push that check as far toward production as you can. It comes in two halves.

**Half one: give the agent eyes on the running UI.** Instead of only asserting
that a handler was called, drive an actual browser: load the page, click the
button as a user would, and assert on what actually happened — the clipboard now
holds the URL, the toast appeared, the dialog closed. The commodity version of
this is everywhere and free: browser-automation libraries like Playwright or
Puppeteer launch a real (headless) browser, click real elements, and can
screenshot the result. You write, in plain steps, the thing a human tester would
do — "open the share dialog, click copy link, expect a confirmation" — and now a
machine does it every run. My buried-button bug cannot survive a check that
actually tries to click the button, because the click lands on the overlay and
the assertion fails. The screenshot, attached to the run, shows you the overlay
you would never have guessed from the diff.

A coding agent can drive this directly. Hand it the browser tool and a goal
stated as observable outcomes, and it will navigate, interact, and report what it
*saw* — not what it assumes the code does. That is the shift: the evidence is an
observation of the live page, not a sentence the agent wrote about its own work.

**Half two: carry the check through to production.** Eyes on a browser pointed at
`localhost` is a huge step, but my second bug was past that line — the code was
fine locally and simply never reached users. So "done" has to follow the artifact
all the way: merge triggers a release that builds a versioned artifact, the
artifact deploys to the target, and *then* a check runs against the real
production URL and confirms the new behavior is live. Not "the workflow turned
green." A request to the actual endpoint, getting the actual fixed response.

The honest part nobody tells you: that last leg fails constantly, and it fails
quietly. When a deploy is stuck, resist the urge to guess. Walk the layers in
order, because the failure is almost never where you first look:

- **Did the release even build?** Check the pipeline run — a lint or test gate
  may have stopped it before any artifact existed.
- **Did the artifact publish?** A build can pass and the push to the registry
  still fail on credentials or a tag collision.
- **Did the platform accept the new version?** The rollout can be waiting on a
  health check, a quota, or a previous revision that never drained.
- **Is the thing actually receiving traffic?** A new revision can be live and
  serving zero traffic because routing still points at the old one.

Each layer has a log. Read them top to bottom rather than reaching for the fix
you already have in mind. My silent-deploy bug was layer two — the artifact never
published — and I lost a day because I assumed it was my code and started
re-reading the diff instead of reading the deploy log that said, plainly, "push
denied."

## How to try it today

You can do all of this with tools you already have or can install for free:

1. **Pick one critical user path** — login, checkout, the share button,
   whatever would be most embarrassing to break — and write a browser test that
   *acts like a user*: navigate, click, type, and assert on the visible result.
   Playwright or Puppeteer; nothing exotic.
2. **State the success condition as an observation, not an intention.** "The
   confirmation toast is visible after clicking" beats "the click handler runs."
   The first can catch the overlay; the second cannot.
3. **Have your agent run it and read the screenshot, not just the exit code.**
   When the run fails, the picture usually tells you why in one glance.
4. **Add one post-deploy check.** After your pipeline deploys, hit the real
   production URL — a `curl` that asserts the response, or the same browser test
   pointed at the live domain — and let *that* be the thing that says "shipped,"
   not the merge.
5. **When a deploy is stuck, enumerate the layers before you fix.** Build →
   artifact → rollout → traffic. Read each log in order. The bug is rarely the
   first thing you suspect.

None of this requires a special platform. The whole move is one idea applied
twice: stop accepting a *claim* as proof, and replace it with an *observation of
the real thing* — first the running UI, then the running production.

## The limitation this leaves open

Here is the honest gap, and it is the reason there is a Part 5. Eyes on the
running system tell you *whether* something is broken. They do not, on their own,
help the agent understand the code well enough to fix it without flailing — or to
change it safely in the first place. And there is a cost problem hiding here:
every session, the agent re-reads big swaths of the repo just to orient itself,
re-discovering what calls what, paying for all that context, and still missing
the one caller three files over that your change will break.

So the next rung is structural understanding and context economy: giving the
agent a map of the code — who calls what, the blast radius of a change — so it
stops re-reading the whole repo every time, runs cheaper and sharper, and can
refactor without fear of the caller it never knew existed. That is where this
series goes next.

This is Part 4 of a twelve-part ladder, from prompting by feel to a workflow
where "done" is something the system can prove rather than something you hope is
true. Each rung stands on its own. If you do only one thing from this post, make
your definition of "done" include one observation of the real, running thing —
a click on the live page, or a request to the deployed URL — instead of a
sentence about it.

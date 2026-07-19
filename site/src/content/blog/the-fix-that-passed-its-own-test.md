---
title: "The fix that passed its own test"
description: "We pointed a cheap model at two dozen findings in our own codebase and it got every one of its checks to green. One of those fixes quietly broke an unrelated invariant. The run ended in 'stuck' anyway. Here is why that was the right answer."
date: 2026-07-04
author: "kazi team"
tags:
  - coding-agents
  - definition-of-done
  - reconciliation
  - dogfooding
  - series-field-notes
series: "Field Notes"
part: 1
draft: false
---

Last week we ran a long security and architecture review over kazi's own code
and came out with a couple dozen findings. Nothing catastrophic, mostly the
usual sediment: a crash on some malformed input here, a resource leak there, a
supply-chain gap in the release pipeline. The kind of list you file with good
intentions and then never quite get to.

So we did the obvious thing. We turned each finding into a checkable statement,
either a test that has to pass or a grep over a config file that has to come back
clean, and handed the whole pile to a cheap model to grind through. Concretely,
that was `kazi apply --parallel` driving `claude-haiku-4-5`: fix a thing, write a
test that proves it, move on, with all the fixes running as separate tracks at
once.

It went well. Suspiciously well, if I'm honest. Every track converged. Every fix
came back with a passing test attached. Twelve findings, twelve greens. If I had
been grading this by reading the diffs, I would have nodded at all of them,
because each one, read on its own, was correct.

## The fix that broke the thing next to it

One of the findings was a concurrency bug: when a worker times out, its lock
wasn't always getting released. Fine, fixable. The model went in and rewrote the
lock's acquire path to add the missing cleanup. Its new test, "a timed-out
worker's lock gets released," passed. Green, like the rest.

But there is an older test in that file, one nobody touched, that asserts
something a lock exists to guarantee: when a crowd of workers all race for the
same free lock, exactly one of them wins. After the fix, that test came back
saying seven of them won. The rewrite had quietly broken the atomic
compare-and-swap the lock relies on. The fix for a leaked lock had turned the
lock into something that doesn't actually lock.

Read that fix in isolation and it looks great. It closes the leak it was aimed
at, it's clean, it has a test, and the test is green. The problem lives entirely
in a place the fix wasn't looking.

## Why the run said "stuck"

Here is the part I want to sit on. When we set the goal up, we didn't just ask
for the twelve fixes. We added one more gate that only runs after all the
individual fixes have converged: the whole test suite, plus the formatter, over
the entire repository. That gate does not care whether each fix passed the test
it shipped with. It runs everything and asks whether the repository as a whole
still holds together.

The gate went red and stayed red: the same two checks failing three observations
in a row. So the controller did not report "done." It reported `stuck`, with
`next_action: investigate`, and it stopped. The individual fixes were all green
and it still refused to sign off, because the thing it was actually told to
verify was not green.

The model had optimized exactly what it was measured on. Its fix satisfied its
test. It wasn't looking at the lock invariant two files over, because nothing in
its immediate task pointed there. And that is not a knock on the model. A sharper
one writes a more convincing version of the same gap. If "done" had been the
model's own say-so, or mine skimming a tidy diff, a lock that lets seven workers
hold it at once ships to production, and we find out weeks later when two jobs
stomp on each other.

It didn't ship. It couldn't, because "done" was not a report the model got to
write. It was a gate the model could not make green by making its own test pass.

## What it cost, and what it didn't

The cleanup was boring, which is the point. I reverted the one bad fix, confirmed
the other eleven were still green against the full suite, and shipped those. One
finding went back on the list to be redone more carefully. Total damage: a single
`git revert` and an afternoon of no surprises.

Compare that to the version where the run happily reports "twelve of twelve
fixed," because that is what a system built on the agent's own confidence would
have told me. Same twelve fixes. Same broken lock. The only difference is whether
a machine catches it inside the loop or a human catches it during an incident.

There's an irony I can't leave out. The single highest-severity finding on that
review list was, of all things, a bug in how kazi grades against the wrong
snapshot of the code, a way for a checker to miss what the agent actually
changed. And while fixing that and everything else, the cheap model went and
demonstrated the exact failure it exists to prevent: work that passes the check
in front of it while quietly violating one just out of frame. We could not have
scripted a better argument for keeping the definition of done outside the thing
being graded.

That's the whole idea, really. Let the cheap model do the keystrokes. Let it be
wrong in the ordinary, plausible ways models are wrong. Just make sure the thing
that decides whether the work is finished is not the same thing that did the
work, and that it checks what actually matters instead of only what the fix chose
to look at. What gets to call the work "done" is the gate, not the model's
summary of its own effort. A run that can say "stuck" when the work isn't
finished is worth more than one that always says "done."

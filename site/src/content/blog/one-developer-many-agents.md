---
title: "One developer, many agents (and how to recover)"
description: "One agent at a time leaves your backlog crawling, so eventually you run two or three at once — and discover that giving each its own task is not enough to keep them out of each other's way. Two agents can hold completely different tasks and still edit the same files, because a task says who owns the work, not who is allowed to touch the code. The rung up is coordinating on resources (the files a change touches) instead of identities, plus the small discipline that makes parallel runs survivable: a preflight check before you fan out, and a way to resume a halted run without redoing the work that already finished."
date: 2026-06-25
author: "kazi team"
tags:
  - vibe-coding
  - coding-agents
  - parallelism
  - series-from-vibe-coding-to-reconciliation
series: "From Vibe Coding to Reconciliation"
part: 9
draft: false
ogImage: /blog/art/part-09.svg
heroAlt: 'Header art for Part 9 of "From Vibe Coding to Reconciliation": One developer, many agents. A rung-9-of-12 position marker on the kazi gradient.'
---

I had a backlog of eight small, mostly independent tasks and one agent working
them one at a time. It was fine, and it was slow. Each task took the agent ten or
fifteen real minutes — read the repo, make the change, run the checks — and I sat
there watching a single stream of work crawl down a list I could see was wide, not
deep. So I did the obvious thing: I opened a second terminal, started a second
agent on a second task, and felt briefly clever. Then a third. Three agents, three
tasks, one repo. The list started moving.

Twenty minutes later two of them had quietly trampled each other, and I spent the
next half hour untangling a mess that was entirely my fault.

## The wall I hit: different tasks, same files

Here is exactly what happened, because the shape of it is the whole point. Agent A
had the task "add an order-search endpoint." Agent B had "add a CSV export of
orders." These are different tasks. I had even been careful — each agent knew which
task was *its* task, and neither would touch the other's. I thought that was the
coordination handled.

It was not, because both tasks needed to touch the same two files. To add a route,
each agent edited the central router. To read orders, each agent edited the same
orders module. Agent A added its route and its query function and committed. Agent
B, working from the version of those files it had read *before* A's commit, added
its own route and its own function and committed on top — and silently dropped A's
route registration, because B's editor had never seen it. Both agents reported
"done." Both were, by their own lights, telling the truth (this is the same
honesty trap from the last rung, now wearing a second hat). The search endpoint
had simply ceased to exist, and nothing either agent checked would ever notice,
because each one's checks passed *in isolation*.

That is the wall: **a task tells you who owns the work; it does not tell you who is
allowed to touch the code.** I had locked the wrong thing. I had given each agent
an *identity lock* — "this task is mine, hands off" — when collisions do not happen
along task boundaries. They happen along *file* boundaries. Two non-overlapping
tasks can map onto wildly overlapping files, and the moment they do, an
identity lock waves them both straight through into the same lines.

This is not a problem you can out-discipline by writing better task descriptions.
You can split the backlog perfectly cleanly and still have two "independent" tasks
collide, because independence at the level of *intent* says nothing about overlap
at the level of *bytes on disk*. The lock has to live where the collision lives.

## The technique: lock resources, not identities

The fix is a shift in what you coordinate on. Stop coordinating on *who is doing
what* and start coordinating on *what each change will touch* — its blast radius.
The unit of contention is the resource: a file, a directory, a path glob, a
migration, a shared config. Before an agent starts changing something, it should
acquire a lease on the resources that change will touch, and any other agent whose
work would touch the same resources has to wait or pick different work. The lease
is on the bytes, not the task.

Two commodity pieces make this real, and you already have both.

**Physical isolation with worktrees.** A git worktree is a second working
directory backed by the same repository, on its own branch. Give each agent its
own worktree and the most violent class of collision — two processes writing the
same file on disk at the same time — simply cannot happen, because they are not
sharing a working directory at all:

```
git worktree add ../wt-search   -b feat/order-search
git worktree add ../wt-export   -b feat/csv-export
```

Now Agent A lives in `../wt-search` on `feat/order-search` and Agent B in
`../wt-export` on `feat/csv-export`. They commit independently; nobody overwrites
anybody's open file. Worktrees do not, by themselves, prevent the *logical*
collision — both branches can still edit the router, and you will meet that as a
merge conflict later — but a conflict you resolve at merge time is a thousand times
better than a silent clobber you discover in production. The conflict is the system
telling you the truth; the silent overwrite was it lying.

**A resource lease as an atomic lock.** To prevent the logical collision *before*
it happens, you need a lock that two agents cannot both win. The trick is to use an
operation that is atomic by construction. A git ref update is exactly that: you can
ask git to create a ref *only if it does not already exist*, and that
check-and-create is a single indivisible step, so exactly one of two racing agents
succeeds:

```
# Claim the "orders module" resource. The all-zero old-value means
# "this must not currently exist" — atomic create-or-fail.
git update-ref refs/leases/orders-module HEAD 0000000000000000000000000000000000000000
# exit 0 → you hold the lease. non-zero → someone else holds it; do other work.
```

Name the ref after the *resource* (`refs/leases/orders-module`,
`refs/leases/router`), not the task. An agent about to edit a resource tries to
claim every lease in its blast radius first; if any is already held, it backs off
and either waits or claims a different task whose resources are free. When it
merges, it deletes its leases. Push the leases to a shared remote and the same
atomicity coordinates agents across different machines — the second pusher gets a
rejection instead of a win. No lock server, no database, no new tool: a ref and the
fact that git refuses to create the same one twice.

Put together, the rule is one sentence: **isolate with worktrees so concurrent
writes are impossible, and lease resources so concurrent intentions are
serialized.** Identity never enters into it. It does not matter *who* the agent is
or *which* task it holds; it matters only which bytes the change will touch.

## Making parallel runs survivable

Parallelism multiplies throughput and it multiplies failure modes. With one agent,
a crash is a crash and you start it again. With five, one can wedge while four sail
on, and the wreckage — a half-finished branch, an orphaned lease, a worktree
pointing at a deleted branch — is now interleaved with live work. Two small habits
keep this from becoming a daily tax.

**Preflight before you fan out.** Most multi-agent runs that stall do not stall on
anything subtle; they stall on something that was already broken before the first
agent started, multiplied across all of them. So check the boring things *once*,
up front, in the parent session, before spawning anyone:

- **Auth is fresh.** If your token or credential expires mid-run, every agent that
  needs to push dies at the same instant, and they cannot recover themselves. Confirm
  you can actually authenticate and push *now*, not "probably."
- **The base is green.** Run the test suite on the branch you are about to fan out
  from. Never spawn five agents onto a base that is already red — you will not be
  able to tell their breakage from the breakage that was already there.
- **There is room to work.** Disk space and the basic ability to create a worktree
  and push a scratch branch. Cheap to check, miserable to discover at agent four.
- **No stale worktrees or leases from last time.** `git worktree list` and a glance
  at your lease refs; `git worktree prune` and delete abandoned leases so a crash
  from yesterday is not holding a resource hostage today.

A ten-line script that runs those four checks and refuses to fan out on a failure
will save you more grief than any amount of cleverness during the run. Agents
cannot fix an expired token or a broken base; they just stall. Fix it before they
start.

**Resume without redoing.** When a run halts halfway — you aborted it, the network
dropped, one agent wedged — the recovery question is "what is actually finished?"
and the answer must come from the repository, not from memory or from what an agent
*told* you before it died. Git already records the truth: which branches merged,
which commits landed, which checks passed. Classify the backlog against that state —
done (merged and green), in-flight (a branch with commits but not merged), untouched
(no branch) — and restart only the work that is not finished. The whole reason to
keep each agent on its own branch and worktree is that this classification is
trivial afterward: finished work is durable in git, so resuming is a matter of
*reading* state, never re-running it. A resume that redoes completed work is just a
slower crash.

One distinction worth keeping straight, because it changes how you set up the run.
An **ad-hoc crew** is a handful of agents you spin up for a single mission with no
pre-declared task list — they explore, divide the work as they discover it, and
disband when it is done; good for "go figure out and fix X." A **planned pool**
works a written backlog with declared dependencies: agents claim tasks (and the
resources those tasks touch) from a shared list and keep going until it is empty;
good for "here are twenty known tasks, drain them safely." A crew negotiates scope
as it goes; a pool reads scope from a plan. Both want the same resource-lease and
worktree discipline underneath — they differ only in whether the work is discovered
or declared.

## How to try it today

On your next batch of parallel work, with nothing but git:

1. **One worktree per agent.** `git worktree add ../wt-<name> -b feat/<name>`.
   Never run two agents in the same working directory.
2. **Lease the blast radius, not the task.** Before an agent edits a shared file,
   claim an atomic ref named for that resource. If the claim fails, it does other
   work. Delete the lease on merge.
3. **Preflight once, in the parent.** Auth, green base, disk, stale-worktree sweep —
   a tiny script that aborts the fan-out if any check fails.
4. **Let merges surface conflicts.** Integrate the branches through a normal merge
   so logical overlaps appear as conflicts you resolve, never as silent overwrites.
5. **Resume from git, not from memory.** On restart, classify each task by its real
   branch/merge/check state and rerun only what is unfinished.

None of this needs a lock server or an orchestration platform. A worktree, an
atomic ref, and a four-line preflight will let you run several agents over one repo
today without the half-hour untangle I earned the hard way.

## The limitation this leaves open

So now I can run several agents at once without them clobbering each other, and pick
the pieces back up when one falls over. The throughput problem is, mostly, solved.

But look at what I am actually *doing* across all of it, and at every rung before
it. For each agent I declare what the finished state should look like, set it loose,
check the result against reality, and either accept it or send it back around. Now I
am doing that several times in parallel and hand-coordinating the leases, the
worktrees, the preflight, and the resume between them. It works, and it is entirely
manual — a loop I am running in my head and re-improvising every session, scaled
out by sheer attention.

That repetition is a clue. The same shape keeps appearing: declare the desired
state, drive an agent toward it, check against reality, repeat until it holds or you
stop honestly. Memory, eyes, plans, an objective "done," and now parallel
coordination — they are not nine unrelated tricks. They are nine instances of one
pattern I have been hand-rolling without naming. Part 10 names it.

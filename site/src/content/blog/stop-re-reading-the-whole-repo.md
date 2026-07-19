---
title: "Stop re-reading the whole repo (and refactor without fear)"
description: "Every session, the agent re-reads big swaths of your code just to orient itself — paying for all that context and still missing the one caller three files over. The next rung is structural understanding: a map of who calls what, so you feed the agent a sharp slice instead of the whole repo, and reshape code in an ordered sequence that keeps the build green at every step. With an honest note on when a map earns its keep and when grep is just fine."
date: 2026-06-25
author: "kazi team"
tags:
  - vibe-coding
  - coding-agents
  - refactoring
  - context-economy
  - series-from-vibe-coding-to-reconciliation
series: "From Vibe Coding to Reconciliation"
part: 5
draft: false
ogImage: /blog/art/part-05.svg
heroAlt: 'Header art for Part 5 of "From Vibe Coding to Reconciliation": Stop re-reading the whole repo. A rung-5-of-12 position marker on the kazi gradient.'
---

I asked the agent to rename one function. It read eleven files to do it, narrated
its way through each, missed a twelfth where the function was called inside a
template string, and handed me a change that compiled locally and broke a caller
I never saw in the diff. The rename itself was trivial. What was not trivial was
that the agent had no idea where the function was *used* — so it did what I do
when I am lost in an unfamiliar codebase: it started reading from the top and
hoped to stumble onto everything that mattered.

That is the wall this post is about. The last four rungs gave "done" an objective
gate, gave your project's knowledge a home, and gave the agent eyes on the
running system. But the agent still walks into your repo every session like it is
the first time — re-discovering what calls what, paying for all that context in
tokens and latency, and *still* missing the caller three files over. You feel it
in two places: runs that cost more and wander more than they should, and the
specific terror of a refactor, where the thing that bites you is always the
dependency you did not know existed.

## The wall I hit

Two versions of the same problem, a week apart.

The first was cost and aim. I had a small change to make inside a sprawling
module, and the agent's opening move — every single time — was to slurp the whole
file into context "to understand the structure." Most of what it read had nothing
to do with the two-line change. I was paying for a full re-read to answer a
question — *what does this change touch?* — that has a precise, small answer. The
agent was sharp once it found the spot; it just took the scenic route to get
there, and the scenic route is not free.

The second was the rename above, and it was scarier because it was silent. The
agent changed the function and every call site it had happened to read. The ones
it had not read — a dynamic dispatch, a call inside a test helper, one buried in
a string template — it left pointing at a name that no longer existed. Nothing in
its context told it those callers were there, so nothing told it the job was
unfinished. "Looks done" again, one rung up.

Same root cause both times: the agent had no *map*. It had the code, but not the
structure of the code — who calls what, who imports what, what a given change can
reach. Without that map, orientation is a full re-read and a refactor is a guess.

## The technique: map the structure, then feed the slice

The fix is to make the structure of the code *queryable* — separately from
reading the code itself — and then to use that map for two things: spending less
context, and changing code safely.

**Build a map of relationships, not just files.** The thing you want to ask is
not "show me this file" but "show me every place that calls this function," "what
does this depend on," and "if I change this, what can it reach?" There is a
commodity answer to every one of those:

- *Find references / callers.* `grep -rn "functionName(" .` gets you most of the
  way for a uniquely-named symbol; your editor's "Find all references" and the
  language-server "call hierarchy" do it with type awareness; `ctags` builds a
  symbol index in seconds.
- *Imports / dependents.* `grep` the import path, or your build tool's dependency
  output.
- *Blast radius.* Callers of callers — run the reference search transitively, one
  hop at a time.

The richer version is a **code graph**: a tool that parses the repo once into a
structural index (functions, calls, imports, tests) and lets you query
relationships directly — *callers of X, callees of X, tests covering X, the impact
radius of changing X* — without re-reading source every time. I reach for one when
a repo is big enough that grep gets noisy. But the graph is the *illustration*,
not the requirement: the technique is "query the structure instead of re-reading
the files," and you can do that today with tools you already have.

**Then feed the agent the slice, not the repo.** Once you can name exactly what a
change touches, you stop pasting whole files into context. Hand the agent the
target function, its direct callers, and its direct callees — the minimal
neighborhood the change lives in. The run gets cheaper because you are not paying
to re-read the irrelevant 90%, and *sharper* because the agent's attention is on
the part that matters instead of diluted across everything. Context economy and
accuracy turn out to be the same lever: a smaller, more relevant context is also a
more correct one.

## Refactor without fear: a worked ordered change

The same map turns a scary refactor into a sequence of boring, safe steps. The
trick is the **expand-then-contract** pattern: never break callers in one heroic
commit. Add the new shape, move callers to it one at a time, and remove the old
shape only once the map says nothing points at it anymore.

Concrete example. Say you want to change a widely-used function

```js
// before: positional args, used all over the codebase
function sendEmail(to, body) { /* ... */ }
```

into a single options object so you can add a `replyTo` field without breaking
the call sites:

```js
// after: one options object
function sendEmail({ to, body, replyTo }) { /* ... */ }
```

First, ask the map for the blast radius: `grep -rn "sendEmail(" .` (or
`callers_of sendEmail` if you have a graph). Say it finds 14 call sites across 9
files, 3 of them in tests. That number *is* the plan. Now walk it so the build
stays green after every commit:

1. **Add the new shape alongside the old.** Introduce `sendEmailOpts({ to, body,
   replyTo })` with the real implementation; leave `sendEmail(to, body)` exactly
   as it is. Build is green — nothing calls the new function yet, nothing changed
   for existing callers. Commit.
2. **Make the old shape delegate to the new.** Rewrite `sendEmail(to, body)` as a
   one-line shim: `return sendEmailOpts({ to, body })`. Behavior is identical, all
   14 callers compile, the tests pass. Build is green. Commit.
3. **Migrate callers one cluster at a time.** Using the caller list as a checklist,
   convert call sites to `sendEmailOpts(...)`, one file (or small group) per commit,
   building after each. Re-run the reference query and watch the old-shape caller
   count tick *down* — 14, then 11, then 6 — a countdown you can see, not a leap of
   faith.
4. **Contract.** When the query returns zero callers of `sendEmail`, delete the
   shim and rename `sendEmailOpts` back to `sendEmail`. Build is green. Commit.

At no point is the tree broken, every step is independently revertible, and the
map — not your memory — tells you when it is safe to delete. The point is the
*order*, and the order comes from the map. It is also the shape of instruction a
coding agent follows well: "here is the caller list; do step 3 one file per commit;
build after each; stop if it goes red." You have turned "refactor this, carefully"
— which invites a guess — into a bounded, checkable sequence.

### Sidebar: the same idea works on what you read

"Structure is queryable" is not only a code trick. The next time you read a dense
paper, a long postmortem, or a sprawling RFC, ingest it into your notes the same
way you would ingest code into a graph: pull out the claims, decisions, and
gotchas, and link them to what you already have. Then you can ask your notes the
cross-document questions — *what here contradicts that ADR? which two sources
actually agree?* — instead of re-reading three documents to rebuild the link in
your head. The commodity version is a notes folder plus `grep` and a habit of
linking; a knowledge wiki or an embeddings search is the richer one. Same lever as
the code graph: turn a re-read into a query.

## When a map helps — and when grep is just fine

Be honest, because the no-hype rule cuts both ways: standing up a code graph is
not free, and for a lot of work plain search wins.

**Grep is enough when:** the symbol name is unique, the repo is small enough to
hold in your head, the change is local, or you just need one answer and move on.
Building an index for a five-file project is ceremony — `grep` and your editor's
"find references" will out-run it.

**A graph earns its keep when:** names are ambiguous or overloaded (so grep
returns a haystack), you need *transitive* blast radius (callers of callers of
callers), the codebase spans languages or is too large to re-scan cheaply, or —
the one that matters most here — you are paying an agent to re-derive the same map
every session. Then caching the structure once and querying it is the difference
between a cheap, aimed run and an expensive, wandering one.

One caution for both worlds: a graph sees only what it parsed. Reflection,
string-based dispatch, route tables, and code generation are invisible to it.
Before you *delete* anything because the map says it has no callers, grep for the
name as a plain string to catch the dynamic references the parser never saw. The
map narrows the search; it does not replace your judgment about the parts no
parser can see.

## The limitation this leaves open

Here is the honest gap, and it is the reason there is a Part 6. Notice what just
happened in the refactor section: I wrote out a careful instruction — *get the
caller list, expand, migrate one commit at a time, contract when the count hits
zero* — and that instruction is good. It is also something I will type again next
week, slightly differently, re-explaining the same procedure to the agent from
scratch every time I need it.

A sharp single run is a real win. But the procedure that made it sharp is still
trapped in a prompt I keep re-typing. The map stops the agent re-reading the repo;
it does nothing about *me* re-writing the same good instructions. So the next rung
is codifying the prompt you keep retyping into something reusable — turning a
one-off bit of cleverness into a workflow you invoke instead of re-explain. That
is where this series goes next.

This is Part 5 of a twelve-part ladder, from prompting by feel to a workflow where
"done" is something the system can prove rather than something you hope is true.
Each rung stands on its own. If you do only one thing from this post, the next
time you ask an agent to change a widely-used function, get the caller list
*first* — then expand, migrate, and contract in that order, so the build stays
green the whole way down.

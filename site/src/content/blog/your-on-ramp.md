---
title: "Your on-ramp"
description: "Twelve posts ago this series started where almost everyone starts: prompting a coding agent by feel and trusting it when it said \"done.\" Each rung after that was one more piece of structure we reached for when that trust broke — memory, eyes on prod, a written plan, an objective gate, parallel agents that recover — and the last two posts named the loop underneath all of them and handed it to a controller. This final post is the on-ramp: a recap of the whole ladder so you can start at whatever rung you are actually on, an honest pass on hardening your harness before you let an agent run unsupervised, the copy-paste wiring to drive kazi from your coding agent, where the project is genuinely going next, and a respectful invitation to try it on something real."
date: 2026-06-25
author: "kazi team"
tags:
  - vibe-coding
  - coding-agents
  - reconciliation
  - kazi
  - series-from-vibe-coding-to-reconciliation
series: "From Vibe Coding to Reconciliation"
part: 12
draft: false
ogImage: /blog/art/part-12.svg
heroAlt: 'Header art for Part 12 of "From Vibe Coding to Reconciliation": Your on-ramp. A rung-12-of-12 position marker on the kazi gradient.'
---

This is the last post, so let me say the thing the whole series has been quietly
built around: you do not have to climb this ladder in order, and you do not have
to climb all of it. Most of the value showed up at each rung independently. The
arc only looks like a straight descent in hindsight; in practice I grabbed
whichever piece of structure the current wall demanded, and so will you.

So this post does four things. It recaps the ladder, with links, so you can find
the rung you are actually standing on. It covers the one piece of homework that
belongs *before* you hand an agent the keys — hardening your harness. It gives you
the exact wiring to drive kazi from your coding agent. And it tells you, honestly,
where this is going next, with the parts that are not built yet labelled as such.

## The ladder, in one screen

Eleven posts, eleven walls, eleven techniques. Here is the whole climb — start
wherever the description matches your last bad afternoon:

1. **[The ceiling of "looks good to me"](/blog/the-ceiling-of-looks-good-to-me)** —
   the agent decides it is done and is subtly wrong, and your eyeball review is the
   only thing standing between that and `main`. The bottleneck is not the model;
   it is the missing objective gate.
2. **[Teach your agent to remember](/blog/teach-your-agent-to-remember)** — a
   committed conventions/memory file any agent reads at startup, so it stops
   re-learning your repo every session.
3. **[Decisions need a home](/blog/decisions-need-a-home)** — separate homes for
   architecture, decisions, operations, and invariants (design doc / ADRs /
   devlog / lore), plus the ten-minute habit that keeps them from rotting.
4. **[Give your agent eyes (all the way to prod)](/blog/give-your-agent-eyes)** —
   drive a real browser, screenshot, probe the deployed thing, so "green locally"
   becomes "exercised live."
5. **[Stop re-reading the whole repo](/blog/stop-re-reading-the-whole-repo)** —
   query the structure (callers, blast radius) instead of re-reading files, feed
   the agent the slice not the repo, and reshape code without fear.
6. **[From prompts to skills](/blog/from-prompts-to-skills)** — the good prompt you
   keep retyping, named, written down once, and invoked by reference.
7. **[Plan the work, then work the plan](/blog/plan-the-work-then-work-the-plan)** —
   intent as an artifact: a checkable plan, tasks tied to outcomes, dependencies
   declared out loud.
8. **[A definition of "done" that can't lie](/blog/a-definition-of-done-that-cant-lie)** —
   why the agent's opinion is not a gate, and what a gate that can come back *red*
   actually looks like (including a hostile adversary pass).
9. **[One developer, many agents](/blog/one-developer-many-agents)** — run several
   agents without collisions by coordinating on blast radius, not identity, plus a
   preflight check and resume-from-where-you-stopped.
10. **[The pattern underneath: reconciliation](/blog/the-pattern-underneath-reconciliation)** —
    every rung above is the same loop: declare desired state, drive an agent, check
    against reality, repeat. Truth lives in the controller.
11. **[Meet kazi: "done," proven](/blog/meet-kazi-done-proven)** — the tool that
    packages rungs 7–10 into an actual controller you hand a goal to.

If you have only done two or three of these, you are not behind. Pick the rung that
matches the pain you felt most recently and start there. The series was written so
each post pays for itself even if you never reach the bottom.

## Before you hand over the keys: harden your harness

There is one rung the ladder above does not have, and it belongs right here, at the
moment you are about to let an agent run *unsupervised* — converging against your
real repo, lap after lap, while you are not watching. A reconcile loop is only as
trustworthy as the agent it drives, and that agent runs inside a harness you may
have configured months ago and never audited. Before you give it the keys, read the
lock.

This is a real habit, not a slogan, and it is the same four checks on any agent
harness — it is not specific to one tool:

- **Hooks.** Many harnesses let you run a shell command automatically on events
  (before a tool call, after an edit, on session start). A hook is arbitrary code
  executing with your privileges. Read every hook you have configured and confirm
  you still trust what it runs and where it came from. A forgotten "run this script
  on every change" hook is the fastest way for an autonomous loop to do something
  you did not intend.
- **Permissions.** Most harnesses have an allow/deny list for what the agent may do
  without asking — which commands run unprompted, which paths it may write. Over-broad
  allow rules (a blanket "yes to all shell," write access to your whole home
  directory) are exactly what bites you once *nobody is watching the prompt*. Tighten
  the allow list to what the task needs; deny the rest.
- **MCP servers / external tools.** Tool servers you connect to the agent can read
  your context and act on your behalf. Audit which ones are wired in, where each came
  from, and whether you would be comfortable with an unattended agent calling it in a
  loop. Remove the ones you cannot vouch for.
- **Secrets.** Grep your harness config, your environment, and your project files for
  plaintext credentials — API keys, tokens, connection strings. An agent that can
  read its own config can leak whatever is sitting in it. Move secrets into a secret
  store or environment the agent does not echo, and never let one land in a committed
  file.

You can do this audit by hand in twenty minutes: open the config, read the hooks,
read the permission rules, list the connected tools, grep for secrets. The point is
that you do it *before* the first unattended run, not after the first surprise. The
loop you are about to trust is only as safe as the harness underneath it.

## The wiring: driving kazi from your coding agent

With the harness audited, here is the on-ramp itself. The thing to understand about
kazi is that **you do not run it directly.** The adoption spine is:

> you → your coding agent → kazi → your coding agent.

You keep working in the conversation you already use. kazi runs the outer loop
behind your agent. The setup is two commands, once.

Install it from the Homebrew tap:

```sh
brew install kazi-org/tap/kazi
```

Then teach your agent the recipe — an opt-in skill that knows how to drive kazi for
you, and nothing else touches your agent's config:

```sh
kazi install-skill
```

From then on you work in two moves, in plain conversation with your agent:

```text
/kazi plan "add a /healthz endpoint that returns 200 ok, with a test, deployed"
/kazi apply
```

`/kazi plan` has your agent turn your prose idea into machine-checkable acceptance
predicates; you glance at them and approve. `/kazi apply` then runs the reconcile
loop — observe, dispatch, re-observe, decide — until every predicate is objectively
true, or it stops and reports `stuck` or `over_budget`. You never have to remember
the verbs, because the skill's trigger is a plain English sentence:

> have kazi drive this until done

Say that to your agent and it runs the same plan-then-apply for you and reports the
result back in the chat. A few read-only verbs are worth knowing for when you want
to see inside the loop: `kazi list-proposed` shows drafted goals awaiting your
approval, `kazi approve` and `kazi reject` move one through its gate, and `kazi
status` reports a run's current state. Every command here is one kazi ships today;
you can confirm the full surface yourself with `kazi help --json`.

## Where this is going (honestly)

A tool you are asked to trust owes you an honest map of what is built and what is
not. The roadmap is public — it lives in the repo's plan, in the open, the same way
this series does. A few directions that are genuinely planned, labelled as **coming**
so you do not mistake them for shipped:

- **A recorded convergence cast and a "done" gallery.** The loop transcript on the
  home page is real, but a recorded cast of a live run and a gallery of goals that a
  prose pipeline left subtly broken — and kazi converged — are **coming**, not yet
  published. When the gallery lands it will carry a reproducible methodology, because
  a proof you cannot reproduce is not proof.
- **Native parallel scheduling.** Today you can run several agents under your own
  pool. A native scheduler *inside* kazi that partitions a goal-set and drives the
  pieces in parallel on a single machine — and a dependency-aware version that reads
  the predicate graph and computes the waves for you — is **planned**, not shipped.
- **More harnesses.** kazi drives several coding agents already; widening that set
  (a recent addition is the Gemini CLI profile) is ongoing.
- **Self-maintaining docs.** The idea from Post 3 — knowledge that lints, trims, and
  refreshes itself — is being built as a kazi standing goal, so kazi reconciles its
  own documentation. In progress, labelled as such.

None of these are required for the on-ramp above to work today. They are where the
controller is headed, written down where you can check the claim.

## A respectful invitation

That is the series. We started by admitting that "looks good to me" is not a gate,
and we ended with a loop that can only say `converged` when an objective gate agrees
— and that says `stuck` or `over_budget` out loud when it cannot get there, instead
of declaring a hollow victory.

If any rung of this ladder described a wall you have actually hit, the honest next
step is small: pick one real goal — not a toy, something with a test and a deploy
you actually care about — write down what "done" means for it as a couple of
checkable predicates, and let the loop run. `brew install kazi-org/tap/kazi`,
`kazi install-skill`, and then, to your agent: *have kazi drive this until done.*

Watch what it does. If it converges, you have your afternoon back. If it comes back
`stuck`, it just told you something true that an eyeball review would have missed.
Either way you will have felt, on your own code, the gap this whole series was about.
That is the only argument for kazi worth making — so go feel it, and tell us what
broke.

# Launch announcement — DRAFT (T25.10)

> **Status: DRAFT for founder review. Nothing here is published.** The
> publish/announce half of T25.10 is founder-gated (operator posts to HN/X). This
> file is the copy only. Every claim below was checked against the shipped product
> during the T25.10 audit; the cost line is deliberately hedged (designed-for, not
> measured) per the repo's no-unproven-cost-figure rule.

The spine every version leads with:

**You describe the outcome → Claude Code authors the checks → kazi loops the agent
until they're objectively true → Claude does the work.** You never run kazi
yourself; your coding agent does.

---

## Hacker News — Show HN

**Title:** Show HN: kazi — an outer reconciliation loop that makes your coding agent's "done" objective

**Body:**

Your coding agent says "done." kazi proves it.

kazi is the outer/reconciliation loop for coding agents. You keep chatting with
Claude Code exactly the way you already do — but instead of trusting the model's
"I'm done," kazi loops the agent against machine-checkable acceptance predicates
until every one is objectively true (tests green, the endpoint actually serves
200, the change deployed), or it stops and tells you why (`stuck`, or out of
budget). It never declares victory on the model's say-so.

The flow, and why the loop matters:

1. You describe the outcome you want, in plain English.
2. Claude Code authors the acceptance predicates (`/kazi plan`) — you glance at
   them and adjust.
3. kazi runs the reconcile loop (`/kazi apply`): observe every failing check, let
   the agent edit, re-observe, repeat — converging to a green predicate vector or
   an honest terminal state.

You never operate kazi directly. It's a skill your coding agent drives from inside
Claude Code, so you stay in the one chat you're already in. In plain English, "have
kazi drive this until done" runs the same thing.

A few design decisions that make it more than a wrapper:

- **Objective termination.** Convergence is gated on predicates you can read, not
  on the model's confidence. A predicate is red at t0 or it doesn't count, so the
  loop can't pass a vacuous check.
- **It drives the agent you already use.** Claude Code today, plus Codex,
  opencode, and other harnesses. As the underlying agent gets better, kazi gets
  better for free — it's a loop, not a model.
- **Honest stops.** `stuck` and over-budget are first-class outcomes with
  evidence, not a spinner that never ends.
- **Cost, stated honestly:** the loop is *designed* to grind on a cheaper model
  tier and escalate only when it's stuck — an intended economics we haven't
  published a measured dollar figure for yet, so we're not going to claim one.

There's a real recorded convergence loop (not a mockup) on the README and at
https://kazi.sire.run/proof — a goal whose one predicate ("`go test` passes") is
false at t0, driven to green by the harness.

Open source, Apache-2.0. Install:

    brew install kazi-org/tap/kazi
    kazi install-skill

(or the Claude Code plugin — one marketplace install bundles the skill, MCP
server, and session-bus hooks.)

Repo: https://github.com/kazi-org/kazi · Site: https://kazi.sire.run

Happy to answer anything about the reconcile model, the predicate providers, or
how termination is decided.

---

## X / Twitter thread

**1/**
Your coding agent says "done." kazi proves it.

kazi is an outer reconciliation loop for coding agents: you chat with Claude Code
like always, and kazi loops it until every acceptance check is *objectively* true —
or stops and tells you why.

Open source. 🧵

**2/**
The spine:

→ You describe the outcome, in plain English
→ Claude Code authors the acceptance predicates
→ kazi loops the agent until they're objectively true
→ Claude does the actual work

You never run kazi yourself. Your agent drives it, from inside your chat.

**3/**
Why a loop?

"Done" from a model is a vibe. kazi makes it a checked fact: tests green, the
endpoint serves 200, the change deployed. A predicate is red at t0 or it doesn't
count — so the loop can't pass a vacuous check.

**4/**
It drives the agent you *already* use — Claude Code today, plus Codex, opencode,
and more. As the underlying agent improves, kazi improves for free. It's a loop,
not a model.

And when it can't get there, it says `stuck` or out-of-budget — with evidence, not
a spinner.

**5/**
Cost, honestly: the loop is designed to grind on a cheaper tier and escalate only
when stuck. That's the intended economics — we haven't published a measured dollar
figure, so we won't claim one.

**6/**
There's a real recorded convergence run (not a mockup): a goal that's failing at
t0, driven to green.

Proof + docs: https://kazi.sire.run/proof

**7/**
Try it in ~10 seconds:

  brew install kazi-org/tap/kazi
  kazi install-skill

then, in Claude Code:

  /kazi plan "add a /healthz endpoint that returns 200 ok, with a test, deployed"
  /kazi apply

Apache-2.0 · https://github.com/kazi-org/kazi

---

## Claim → source map (for the founder's pre-post check)

| Claim in the copy | Where it's true in the shipped product |
|---|---|
| "Your coding agent says 'done.' kazi proves it." | Canonical HERO_TAGLINE (README + site/src/canonical.mjs) |
| "outer/reconciliation loop for coding agents" | Canonical POSITIONING string |
| You never run kazi; the agent drives it | README intro; site index spine section |
| plan → apply flow, plain-English "have kazi drive this until done" | README "Try it in 10 seconds"; INVOCATION_PHRASE |
| Objective termination / red-at-t0 | README "How it works"; no_stubs / predicate docs |
| Drives Claude Code + Codex/opencode/others | canonical HARNESSES list (claude, opencode, codex, antigravity, claw, gemini_cli) |
| `stuck` / over-budget honest stops | README verdict/exit-code section |
| Cost is designed-for, not measured | README:270 "Designed-for, not yet measured" hedge |
| Recorded proof loop, not a mockup | assets/proof-loop.gif + assets/proof-loop.cast; /proof route |
| Apache-2.0 | README license badge |
| brew + install-skill / plugin | README install section; ADR-0077 |

**Not claimed on purpose:** the 12-part blog series is a labeled-forthcoming
scaffold (posts read "coming"), so the copy points at the site/proof, not at
unwritten posts.

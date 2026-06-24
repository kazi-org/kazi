# ADR 0029: Drop the Telegram bridge -- claude is the mobile interface

## Status
Accepted (supersedes the Telegram-bridge portion of ADR-0011; everything else in
ADR-0011 -- the `Kazi.Authoring` write path, the LiveView dashboard -- stands)

## Date
2026-06-24

## Context

ADR-0011 (Slice-3 operator surfaces) shipped a **Telegram bridge** so a human could
declare/approve goals from their phone and receive pings on `converged`/`stuck`/
`over_budget`. It made sense under the original framing: kazi as a standalone
controller a HUMAN drives directly, with the human sitting above kazi.

The architecture has since moved (ADR-0023/0024, the E15-E17 arc): **the
orchestrating agent (Claude Code) drives kazi, and the human talks to the
agent.** That collapses both jobs the Telegram bridge did:

- **Human drives/approves from a phone** -- now the Claude mobile/web app: the
  human says "build X with kazi" and the agent drives `kazi propose --json` ->
  `approve` -> `run`.
- **kazi pings the human on a terminal state** -- now the agent's own push
  (`PushNotification` reaches the phone via Remote Control), emitted by the agent
  that is already driving the run.

So a kazi-native Telegram bridge is **redundant** for the agent-driven workflow --
the human's mobile interface IS the agent. Keeping a second, parallel,
hand-maintained chat surface is dead weight, and carrying dead code contradicts
kazi's own intended-vs-actual / no-dead-code thesis (ADR-0021, E13).

One edge case was considered: **fully headless/autonomous kazi** -- a standing
reconciler running 24/7 (e.g. a cron/CronJob on a server) with NO agent session
attached. There is no agent there to push, so that mode would need its own
out-of-band notification channel. But (a) it is a narrow, not-yet-active use case,
and (b) the general answer is a **generic webhook**, not Telegram specifically.

## Decision

1. **Drop the Telegram bridge.** Remove `Kazi.Telegram` and its client/message
   modules + tests; scrub the "Telegram" surface mentions from moduledocs
   (`Kazi.Authoring`, `Kazi.ReadModel`, the draft/proposed-goal docs), `docs/
   concept.md`, the README, and the site. The bridge has no Telegram-specific
   dependency, so nothing in `mix.exs` changes.

2. **Drop the dependent plan item.** T20.9 (phone-driven pool direction via
   Telegram) is withdrawn -- Claude mobile already covers it.

3. **Keep the LiveView dashboard.** ADR-0011's other Slice-3 surface (the read-only
   LiveView console) is unaffected and stays (T20.8/T21.9 observability).

4. **The headless-autonomous notification need, if it ever activates, is served by
   a future GENERIC webhook** (a single outbound POST on a terminal state), not by
   reinstating Telegram. Recorded as deferred backlog, not built now.

## Consequences

- Less surface to maintain; the codebase matches the architecture (the agent is
  the human's interface). Removing a now-dead surface is the no-dead-code thesis
  applied to kazi itself.
- The agent-driven on-ramp (E17) can state plainly: "your mobile interface is
  Claude Code -- no separate app to wire."
- A one-time code removal (3 lib + 3 test files + doc scrubs), planned as a small
  cleanup epic (E24), kept green by the test suite.
- The headless-autonomous case loses its built-in pinger until a generic webhook
  is added -- acceptable, since that mode is not active and the webhook is the more
  general answer.

## Alternatives rejected

- **Keep the bridge as a legacy/optional surface.** The first instinct, but it
  leaves a parallel hand-maintained surface nothing in the primary workflow uses --
  dead code by another name. The operator chose to drop it.
- **Extend Telegram for the pool (the original T20.9).** Doubles down on a
  redundant channel; the agent's own push already does this.
- **Build a generic webhook now.** No active consumer; deferred until the
  headless-autonomous mode is real.

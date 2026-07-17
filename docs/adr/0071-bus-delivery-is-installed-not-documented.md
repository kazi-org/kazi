# ADR 0071: Bus delivery is installed, not documented — an opt-in turn-boundary hook

## Status
Accepted

## Date
2026-07-16

## Refines / supersedes

Supersedes the **delivery** half of ADR-0067 decision point 6 — the clause
"Delivery into a session is the harness's own hook mechanism calling `kazi bus
read` on turn boundaries; that recipe ships as documentation (AGENTS.md /
docs), because kazi drives harnesses and does not reach into them (ADR-0001/0008
boundary)." The rest of point 6 stands unchanged and is reaffirmed: the
`bus post|read|who|tell` CLI verbs, `--json`, and the matching `kazi mcp` tools
(ADR-0044) remain the surfaces. Every other ADR-0067 decision stands, notably
point 1 (convergence NEVER depends on the bus; every surface degrades cleanly
without a daemon) and point 7 (bus content is advisory, provenance-stamped
input — never a command channel).

## Context

ADR-0067 shipped the bus and left delivery as a recipe. The recipe's observed
install rate is **zero**.

With a `kazi daemon` up for ~16 hours carrying a dozen live sessions across two
machines and three projects — presence, facts, and directed messages all
round-tripping correctly — no hook was installed on either machine: no
project-level hook directory, no user-level hook directory, no `hooks` key in
the harness settings. The bus was fully operational and structurally unable to
reach anyone who did not go looking for it.

The consequence is that **the operator is the delivery mechanism**. Every
session that reads the bus does so because a human told it to, and told it
again the next session, and again after each compaction. That is the reported
symptom ("I am having to remind the agents over and over"), and it is not a
discipline failure to be corrected with better wording:

- A recipe competes for attention with the task in front of the session.
  Instruction-following decays with context distance; a "peek at turn
  boundaries" line inside a 561-line skill sits tens of thousands of tokens
  away from the moment it needs to fire.
- This has already been tested. The skill's bus section was enhanced twice
  (the peek/read/watch taxonomy, the destructive-read landmine) with no
  observed change in behaviour. Documentation is the status quo, and the status
  quo is what is being reported as broken.
- The alternatives available to a disciplined session are both bad: `bus watch`
  blocks, so a watching session is not a working session; a `read` poll loop
  bills tokens on every tick whether or not anything happened. Neither is
  delivery — they are a session spending its own budget to discover silence.

**The boundary argument in point 6 is a category error.** ADR-0001 positions
kazi as the outer loop that treats coding agents as a replaceable inner loop
invoked through a thin subprocess harness adapter. ADR-0008 decides that this
invocation is headless and stateless per iteration and that durable context
lives in kazi rather than the CLI session. Both govern **the harness kazi
dispatches**. The reader of the bus is a different actor entirely: the
operator's own driving session, which ADR-0067 decision point 2 explicitly
makes a first-class participant ("Participants: operator sessions AND kazi
runs"). Nothing in ADR-0001 or ADR-0008 speaks to it, and neither is violated
by writing a config file the operator asked for.

The precedent is already load-bearing. ADR-0024 decision 1 has kazi writing
into the harness's own config directory: `kazi install-skill` writes
`SKILL.md` under the harness skills directory, opt-in, such that a normal
`kazi` run never touches it. Installing a hook is the same act, by the same
consent model, into the same directory tree. kazi already teaches the harness
what it can do; it just never taught it to listen.

## Decision

**kazi ships the delivery, opt-in, as an installer — not as a recipe.**

1. **`kazi install-hooks`**, a sibling of `kazi install-skill` under the same
   contract: explicit operator invocation, never implicit. A normal run
   (`apply`, `plan`, `status`, any bus verb) NEVER writes to harness config.
   `--dir` targets a tmp dir so tests never touch a real harness install.

2. **Two hooks, matched to the two moments that matter:**

   | Hook | Fires | Does |
   |---|---|---|
   | session start | new session | registers presence + team for the project scope, injects the current board (ADR-0073) |
   | turn boundary | the next turn begins | injects the digest (ADR-0072) if there is traffic; silent if not |

   The turn-boundary hook is why this ends the token complaint: **it costs
   nothing when the bus is quiet**, and it needs no session to sit blocked or
   polling. Delivery becomes harness mechanics rather than agent virtue.

   **The binding rule: a profile binds ONLY to events whose stdout reaches the
   session's context.** For Claude Code those are `SessionStart` and
   `UserPromptSubmit`; a `Stop`-style event's output never reaches the next
   turn, so binding the digest there would be delivery to nowhere — the recipe
   in ADR-0067's docs suggested exactly that ("a `UserPromptSubmit` or `Stop`
   hook"), and half of that suggestion silently does not deliver. The rule is
   stated here so a future profile cannot repeat the mistake by picking a
   plausible-sounding event.

   **The installed command is `kazi bus hook <event>`** — a kazi subcommand,
   not a script file. The settings block stays one line per event, the payload
   logic lives in the binary where it is unit-testable and upgrades with
   `kazi` itself (no stale script drifting from the binary that installed it),
   and a hard internal wall-clock bound applies: the hook answers within its
   budget or exits 0 silently, because a slow daemon must never tax every turn
   of every session.

   **Amendment (issue #1295): the budget is PER-EVENT.** `turn` is the per-turn
   hot path and keeps the tight 2s bound. `session-start` is a one-shot at boot
   whose full-board drain was measured at ~9.7s under a real busy backlog (127+
   fact topics) — the exact load the board exists for — so a shared 2s bound
   silently shut its board down to nothing. `session-start` therefore gets a
   larger 15s bound (matching the bus's own control-socket call bound); a human
   is already waiting on their session, so the one-shot cost is invisible while
   the hot path stays tight. These MUST NOT be re-collapsed into one constant.

3. **Merge, never clobber.** The installer writes a marked, idempotent block
   into the harness settings, preserving every key it does not own.
   Re-running is a no-op; `--uninstall` removes exactly what was added. An
   operator's existing hooks survive untouched.

   **The default install target is the operator's user-level settings**, not a
   project file: the hook no-ops instantly wherever no daemon is running, so
   user-level costs nothing outside bus-active projects and covers every
   project with one install. `--project` writes the project's *local*
   (uncommitted) settings file instead. The installer NEVER writes a committed
   project file — in a public repo that would publish the operator's internal
   workflow, which the ADR-0034 leak gate exists to prevent.

4. **A hook is a no-op without a daemon.** With the daemon down the hook exits
   silently and the session proceeds identically — ADR-0067 point 1's
   graceful-degradation guarantee extends to delivery. Convergence still never
   depends on the bus.

5. **Injected content is advisory input** (ADR-0067 point 7, restated because
   injection is the moment it matters). A hook folds agent-authored text into
   another agent's context, which is a prompt-injection surface. The injected
   block is provenance-stamped and framed as untrusted external input; it never
   carries authority over the operator.

6. **Harness-agnostic by profile.** The installer targets a harness profile
   (ADR-0016); Claude Code is the first and only profile shipped. A harness
   with no hook mechanism simply has no delivery — its sessions keep using the
   pull verbs, exactly as today.

## Consequences

- The reported symptom ends: a session learns about the bus because the harness
  told it, not because a human did. This is the single highest-leverage change
  available to the bus, and it is small.
- Token cost of awareness drops to zero-when-quiet. The only cost is a digest
  when there is genuinely something to say — which ADR-0072 bounds.
- Every turn now pays the hook's wall-clock, which is why the internal
  timeout in point 2 is part of the decision and not an implementation detail:
  the failure mode "a hung daemon adds seconds to every turn of every session
  on the machine" is worse than any missed digest.
- kazi now has a **write surface in the harness's config**. That is a real new
  responsibility: the installer must be conservative, idempotent, reversible,
  and must never assume it is the only writer. This is the main risk the epic
  must test (R-E55-1).
- `install-skill` and `install-hooks` are now two halves of one story — teach
  the harness to drive kazi, and teach it to listen. They should be
  discoverable together.
- Sessions started before an install are unreachable by push until they restart.
  Delivery is a property of session start, not retroactive.

## Non-goals

- **Not runtime coupling.** kazi does not reach into a live harness process,
  does not inject mid-turn, and does not require the harness to be running. It
  writes a file when asked and is otherwise absent. ADR-0001/0008's actual
  boundary is untouched.
- **Not auto-install.** No `kazi apply` side effect, no first-run prompt, no
  install-on-upgrade. Opt-in stays opt-in (ADR-0024 decision 1).
- **Not a chat UI** (ADR-0067 non-goal, unchanged). The hook delivers a digest;
  it does not render conversation.
- **Not a command channel.** See point 5.

## Alternatives rejected

- **Improve the skill's wording again.** This is the status quo and it is what
  is being reported as broken. Two enhancement passes produced no behavioural
  change, because the failure is structural: the instruction is far away and
  outranked when it needs to fire. A third pass has no mechanism by which to
  work.
- **`bus watch` as the delivery primitive.** Watch blocks; a session parked on
  the bus is not doing work. It is the right tool for "I am deliberately
  waiting on another session" and the wrong tool for ambient awareness. (Its
  own backlog bug is separately fixed by T54.9.)
- **A `read` poll loop on a timer.** Bills tokens per tick to usually learn
  nothing, which is precisely the reported complaint. Polling is what push
  exists to eliminate.
- **kazi injects into the harness at runtime** (wrapping the session, proxying
  its stdio, or driving it via `--resume`). This one genuinely does violate
  ADR-0001/0008 — it makes kazi a harness. Rejected.
- **Ship the hook as an example file in the repo** rather than an installer.
  A file the operator must find, copy, wire, and maintain is a recipe with
  extra steps; it has the same zero install rate for the same reason.

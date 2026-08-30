# ADR-0084: The session-bus hooks require a separate opt-in gate -- installing the Claude Code plugin is no longer sufficient consent by itself

## Status

Accepted

## Date

2026-08-30

## Refines / supersedes

Narrows **ADR-0077 decision 4** in ONE respect: "installing the plugin IS the
opt-in" no longer holds for the bundled session-bus hooks specifically. Every
other part of ADR-0077 stands unchanged -- the plugin still bundles the skill,
the MCP server registration, and the hook DECLARATIONS, lockstep-versioned
with the binary release, generated (never hand-maintained) from the same
sources `install-skill` / `init --with-mcp` / `install-hooks` render from
(T61.3). ADR-0071's consent-first principle for `kazi install-hooks` itself is
unaffected and, if anything, reaffirmed: that command remains the one place an
explicit, standalone opt-in has always lived, and this ADR's marker mechanism
(decision 2 below) reuses it rather than adding a second command.

## Context

Issue #1705 (fleet-observed, 2026-08-30): a machine that installed the `kazi`
Claude Code plugin purely for the skill and the MCP server -- not for the
session bus, which that fleet had already retired as its coordination
mechanism -- still paid a live daemon's full board/digest injection at every
`SessionStart`, measured at 13.6 KB (~3.4k tokens) in one instance. The plugin
manifest wires `SessionStart` / `UserPromptSubmit` / `Notification` to `kazi
bus hook <event>` unconditionally (ADR-0077 decision 1); ADR-0077 decision 4
treated the plugin install ITSELF as sufficient consent for that, reasonable
when the bus hooks were the plugin's main draw, but not once the same
manifest bundles two OTHER components (skill, MCP) an operator can want
independent of the bus.

`kazi install-hooks` (ADR-0071) was already correctly consent-first -- it is
an explicit, standalone command an operator chooses to run. The plugin's
bundled hooks bypass that consent model entirely: there is no separate step
between "I want the kazi skill" and "every session on this machine now pays
the bus hooks' cost," because both arrive in the same `/plugin install`.

## Decision

1. **`kazi bus hook <event>` (`Kazi.Bus.Hook.run/2`) checks a new opt-in
   gate FIRST, before any work -- including before spawning the bounded
   `Task` that would otherwise contact the daemon.** This is the single
   command BOTH install paths invoke (the plugin's declarations and
   `install-hooks`' registrations render the identical `{event, command}`
   set, T61.3), so gating here covers both by construction -- no drift
   possible between "the plugin's hooks are gated" and "the explicit
   installer's hooks are gated." When the gate is not armed, `run/2` is an
   immediate silent exit 0: zero daemon contact, zero latency added to the
   turn, matching the hook contract's existing fail-silent posture (ADR-0067
   point 1) but for an ADDITIONAL reason (not opted in, rather than daemon
   down).

2. **The gate (`Kazi.Bus.HookGate`) is armed by either of two independent
   signals, checked in order, default OFF:**

   - the `KAZI_BUS_HOOKS` environment variable set to `"1"` or `"true"` --
     the cheapest fleet-wide signal, exported once in a shell profile or a
     launch agent's environment;
   - a marker file at `~/.config/kazi/bus-hooks-enabled` -- deliberately
     OUTSIDE `~/.claude` (it gates a kazi-owned command, not a harness
     setting, and must survive a harness settings wipe or plugin reinstall
     untouched).

   `kazi install-hooks` (the explicit CLI command) writes this marker on a
   successful install and removes it after a successful `--uninstall` --
   running that command already IS the explicit consent act (ADR-0071), so
   an `install-hooks` operator gets zero additional manual steps. An
   operator who installed ONLY the Claude Code plugin (no `install-hooks`
   run) gets neither signal, so the plugin's bundled hooks stay silent until
   they opt in via either mechanism.

3. **Non-goals.** This does not touch the plugin manifest's `hooks`
   declarations, which stay generated exactly as ADR-0077 specifies (T61.3)
   -- the plugin continues to bundle skill + MCP + hook DECLARATIONS in one
   install, still lockstep-versioned. It does not add a CLI flag for the
   marker path; the two signals above are the whole surface. It does not
   change `install-hooks`' own settings-file merge/uninstall mechanics
   (ADR-0071 decision 3) -- the gate marker rides alongside that write,
   never inside `~/.claude/settings.json` itself.

## Consequences

- A plugin-only install (skill + MCP, no bus hooks in practice) is now
  actually possible without a separate uninstall step for hooks specifically
  -- the plugin can stay installed and its declared hooks simply do nothing
  until the operator opts in.
- An `install-hooks` operator sees zero behavior change: the marker is
  written automatically, so the hooks they explicitly asked for keep
  working exactly as before.
- An operator upgrading a kazi binary that already has `install-hooks`
  registrations from BEFORE this ADR shipped gets armed on their next
  `install-hooks` re-run (idempotent install also arms the gate, not only a
  fresh one) -- not a silent, surprising loss of delivery after an upgrade.
- The 13.6 KB/session-start cost issue #1705 measured is now paid ONLY by a
  session on a machine that has explicitly armed the gate -- the founder
  ruling's actual ask.
- One more signal for an operator to discover if they DO want the bus hooks
  after a plugin-only install and are confused by the silence; `kazi bus
  hook --help` and `docs/session-bus.md` document both opt-in mechanisms.

## References

- Issue #1705 (this decision), founder ruling 2026-08-30 (the bus retired as
  the fleet's coordination mechanism; the plugin hooks' unconditional cost on
  machines that no longer read it).
- ADR-0067 (session-coordination bus, the fail-silent-when-down contract this
  gate extends), ADR-0071 (`install-hooks`, consent-first, decision 2's
  `{event, command}` set this gate covers unmodified), ADR-0077 (Claude Code
  plugin distribution, decision 4 narrowed here), ADR-0076 (bus delivery is
  installed, not documented).

# ADR 0044: `kazi mcp` as a first-class installed subcommand

## Status
Proposed

## Date
2026-06-24

## Refines
ADR-0024 (kazi is self-teaching to harnesses — which already names "a `kazi mcp`
server" as one of the self-teaching surfaces) and ADR-0031 (the kazi skill router).
This ADR commits the surface that ADR-0024 named but the installed CLI never grew.

## Context

ADR-0024 lists a `kazi mcp` server among the surfaces that let an agent drive kazi
without prose instructions. The server exists — `Kazi.MCP.Server`, exercised today
only through the `mix kazi.mcp` Mix task — and exposes `kazi_plan`, `kazi_approve`,
`kazi_apply`, `kazi_status`, and `kazi_list_proposed`.

But the **installed** binary has no `mcp` verb. `lib/kazi/cli.ex` dispatches
`apply | plan | status | help | schema | version` only. An agent that installed
kazi via Homebrew (ADR-0014) — the supported distribution path — cannot start the
MCP server at all; `mix kazi.mcp` requires a source checkout and a Mix toolchain
that an installed-agent environment does not have.

This forces every outer agent onto the JSON-CLI fallback and onto prose in
`AGENTS.md` to learn the surface, which is exactly the context cost ADR-0024 set out
to remove. MCP tool descriptions + input/output schemas teach the agent at zero
prose cost; the CLI path teaches nothing until the agent reads docs.

## Decision

1. **Add an installed `kazi mcp` subcommand** that wraps the existing
   `Kazi.MCP.Server` over stdio. It is the same server `mix kazi.mcp` starts today;
   only the entry point is new. No new tools are introduced by this ADR — it is a
   distribution/packaging decision, not a protocol change.

2. **The canonical client config becomes:**

   ```json
   { "mcpServers": { "kazi": { "command": "kazi", "args": ["mcp"] } } }
   ```

   This is what `kazi install-skill` / `kazi init --with-mcp` (ADR-0024) emit, and
   what the docs and generated skills reference.

3. **`kazi help --json` documents the `mcp` verb**, and the self-conformance test
   (the harness-onboarding contract, ADR-0022/0023) asserts that every advertised
   verb — including `mcp` — is dispatchable on the installed binary. This keeps the
   doc-freshness gate (ADR-0036) honest about the new surface.

4. **`mix kazi.mcp` stays** as the development entry point; it and `kazi mcp` share
   the one server module so they cannot drift.

## Consequences

- An installed agent can add kazi as an MCP server with one stable command and learn
  the whole surface from tool schemas — the prose in `AGENTS.md` describing how to
  shell out to `kazi --json` shrinks to a fallback note.
- The on-ramp ADR-0025 sequences against ("after the install-skill/mcp on-ramp
  ships") gains its missing leg: the MCP server is now reachable from the binary the
  on-ramp tells people to `brew install`.
- Burrito packaging must include the MCP server path in the installed release — a
  build concern to verify, not a code change (the module already ships in the OTP
  release).
- Risk: stdio framing / non-TTY behavior must match what MCP clients expect. Bounded
  — the server already runs this way under `mix kazi.mcp`; this ADR only changes how
  it is launched, so a launch-parity smoke test (start via `kazi mcp`, list tools,
  call `kazi_status`) is sufficient.

## Alternatives rejected

- **Keep `mix kazi.mcp` only.** Zero work, but leaves ADR-0024's named surface
  unreachable from the supported install path — the agent UX stays prose-heavy,
  defeating the self-teaching goal.
- **Ship a separate `kazi-mcp` binary.** A second artifact to build, sign, tap, and
  version. A subcommand on the one binary is simpler and keeps `kazi help` the single
  index of the surface.
- **Expose MCP over a TCP/HTTP port instead of stdio.** Adds a listener, a port to
  manage, and an auth surface. Stdio is what the local MCP clients (Claude Code,
  Codex, Cursor) expect for a locally-installed tool; a network transport can be a
  later additive option if a remote-driver use case appears.
</content>
</invoke>

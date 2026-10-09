# `kazi mcp` — reusable registry-listing metadata

Prepared once (T25.13), reused verbatim across every MCP registry submission
(official MCP registry, mcp.so, Smithery, glama.ai, `punkpeye/awesome-mcp-
servers`) so each PR/form is a paste, not a rewrite. Fields checked against
the shipped server (`lib/kazi/mcp/server.ex`) and `kazi help --json` — update
this file, not each registry, when the tool surface changes.

## Identity

- **Name:** kazi
- **Package/binary:** `kazi` (Homebrew tap `kazi-org/tap/kazi`; release
  binaries at `github.com/kazi-org/kazi/releases`)
- **Homepage:** https://kazi.sire.run
- **Repository:** https://github.com/kazi-org/kazi
- **License:** Apache-2.0
- **Server verb:** `kazi mcp` (stdio transport; `kazi init --with-mcp`
  scaffolds the client config)

## One-line description

Reconciliation controller for coding agents — declare a goal as
machine-checkable acceptance predicates, `kazi mcp` drives a coding harness
(Claude Code, opencode, Codex, Gemini CLI) in a loop until the predicates are
objectively true, stuck, or over budget.

## Longer description (for forms with a description field)

kazi is the outer/reconciliation loop for coding agents. Instead of trusting
an agent's own "done" claim, you author a goal as a vector of
machine-checkable acceptance predicates (tests, coverage, live probes,
custom scripts), then `kazi apply` drives a harness in a loop against them
until every predicate is objectively true — or the run stops honestly as
`stuck` or `over_budget`. Guard predicates, ratchets, and enforcement
(`read_only_paths`) stop the agent from gaming its own grader. Harness-
agnostic (Claude Code, opencode, Codex, Gemini CLI) and Apache-2.0.

## Transport

stdio (`{"mcpServers": {"kazi": {"command": "kazi", "args": ["mcp"]}}}`)

## Tools exposed

| Tool | What it does |
| --- | --- |
| `kazi_plan` | Draft acceptance predicates for a goal from a prose idea |
| `kazi_approve` | Approve a drafted proposal into a runnable goal-file |
| `kazi_apply` | Converge a goal — drives the harness loop until true/stuck/over-budget |
| `kazi_status` | Report on a run or proposal's lifecycle state |
| `kazi_list_proposed` | List drafted proposals awaiting approval |

Agent communication uses the independent [Ajent client](https://github.com/ajent-social/ajent).

## Example config (for forms that want a config snippet)

```json
{
  "mcpServers": {
    "kazi": {
      "command": "kazi",
      "args": ["mcp"]
    }
  }
}
```

## Category/tags

coding-agent, reconciliation-loop, agentic-verification, developer-tools,
elixir, ci-cd, testing

## Auth

None — local stdio process, no OAuth/API keys required by the MCP server
itself (the harness it drives may need its own provider key, e.g.
`ANTHROPIC_API_KEY`).

## Status

Registered here 2026-07-19 (T25.13). Submission tracked as:
- Agent-executable listing PRs (this repo does not own): mcp.so, Smithery,
  glama.ai, `punkpeye/awesome-mcp-servers` — open once per registry using
  this file verbatim.
- Ownership-gated submissions (operator-only): the official MCP registry and
  the Claude Code plugin marketplace, tracked as OP-21 in
  `docs/marketing/operator-tasks.md`.

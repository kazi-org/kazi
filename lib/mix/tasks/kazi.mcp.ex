defmodule Mix.Tasks.Kazi.Mcp do
  @shortdoc "Run the kazi MCP server (self-describing tools over JSON-RPC stdio)"

  @moduledoc """
  The `mix` entry point for the kazi MCP server (T16.5, ADR-0024 decision 4):

      mix kazi.mcp

  Speaks line-delimited JSON-RPC 2.0 over stdio — the MCP stdio transport — so an
  MCP-speaking harness (Claude Code, or any MCP client) connects and drives kazi
  NATIVELY: `tools/list` returns the self-describing kazi tools (propose,
  approve, run, status, list-proposed), and `tools/call` dispatches each to the
  corresponding kazi function and returns its JSON result. No shelling out, no
  stdout parsing.

  Like `mix kazi.apply`, this task boots the full `:kazi` OTP application first —
  including the native SQLite (exqlite) NIF an escript cannot bundle — so the
  read-model is up and `status`/`list-proposed` read real persisted state. The
  protocol logic lives in the pure `Kazi.MCP.Server.handle_request/2`; this task
  only starts the app and pumps the stdio loop (`Kazi.MCP.Server.serve/1`).

  The launch path — boot with logging muted, redirect logging off stdout, serve —
  is shared with the installed `kazi mcp` verb (T33.1, ADR-0044) through
  `Kazi.MCP.Stdio`, so the development task and the installed binary start the
  SAME server and cannot drift. This task is the development entry point; the
  `kazi mcp` verb is the installed one.

  ## Configure an MCP client

  Point an MCP client at this task as the server command, e.g. in a
  Claude Code `.mcp.json` (development); the installed binary uses
  `{ "command": "kazi", "args": ["mcp"] }` (ADR-0044):

      {
        "mcpServers": {
          "kazi": { "command": "mix", "args": ["kazi.mcp"] }
        }
      }
  """

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    # Boot the app so Kazi.Repo (and the exqlite NIF) are up before the server
    # serves any read-model tool (status / list-proposed) against real state, then
    # hand off to the shared stdio launch path (logging hygiene + the pure,
    # unit-tested serve loop). Blocks until EOF on stdin.
    Kazi.MCP.Stdio.serve(boot: fn -> Mix.Task.run("app.start") end)
  end
end

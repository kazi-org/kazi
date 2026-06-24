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

  A thin `kazi mcp` CLI subcommand can be added later as a tiny follow-up; this
  Mix task is the persistent entrypoint, mirroring `Mix.Tasks.Kazi.Apply`.

  ## Configure an MCP client

  Point an MCP client at this task as the server command, e.g. in a
  Claude Code `.mcp.json`:

      {
        "mcpServers": {
          "kazi": { "command": "mix", "args": ["kazi.mcp"] }
        }
      }
  """

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    # stdout is the MCP transport — it must carry ONLY JSON-RPC messages, so NO
    # log line may land on stdout. Two things print there by default: the app's
    # own runtime logs, and Phoenix's boot logs during `app.start`. Handle both:
    #
    #   1. SILENCE logging across the boot — the `:kazi` app start brings up the
    #      web endpoint, which logs two `[info]` lines; drop them to `:none` so
    #      they never reach the as-yet-unredirected default handler on stdout.
    #   2. After boot, REDIRECT every `:logger` handler that writes to
    #      `:standard_io` over to `:standard_error`, then restore the level — so
    #      all subsequent runtime logging (a tool call's warnings, etc.) goes to
    #      stderr and the JSON-RPC stream on stdout stays clean.
    previous_level = Logger.level()
    Logger.configure(level: :none)

    # Boot the app so Kazi.Repo (and the exqlite NIF) are up before the server
    # serves any read-model tool (status / list-proposed) against real state.
    Mix.Task.run("app.start")

    redirect_logging_to_stderr()
    Logger.configure(level: previous_level)

    # Hand off to the thin stdio transport; the protocol logic is the pure,
    # unit-tested handle_request/2 underneath. Blocks until EOF on stdin.
    Kazi.MCP.Server.serve()
  end

  # Point every `:logger` handler that writes to `:standard_io` at
  # `:standard_error` instead, so no log line lands on stdout (the MCP
  # transport). `:logger` forbids changing a live handler's `type` in place
  # (`:illegal_config_change`), so each such handler is removed and re-added with
  # the same module/config but `type: :standard_error`. Best-effort: a handler
  # that does not re-add cleanly is left as-is (logging still works, on stdout).
  defp redirect_logging_to_stderr do
    for handler_id <- :logger.get_handler_ids() do
      case :logger.get_handler_config(handler_id) do
        {:ok, %{module: module, config: %{type: :standard_io} = config} = handler} ->
          :ok = :logger.remove_handler(handler_id)

          :logger.add_handler(
            handler_id,
            module,
            handler
            |> Map.delete(:id)
            |> Map.put(:config, %{config | type: :standard_error})
          )

        _ ->
          :ok
      end
    end

    :ok
  end
end

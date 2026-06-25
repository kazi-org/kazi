defmodule Kazi.MCP.Stdio do
  @moduledoc """
  The shared stdio launch path for the kazi MCP server (T33.1, ADR-0044).

  Both entry points that start the server over the MCP stdio transport go through
  here so they CANNOT drift:

    * `mix kazi.mcp` (the development entry, T16.5/ADR-0024) passes its
      `Mix.Task.run("app.start")` boot;
    * the installed `kazi mcp` verb (`Kazi.CLI`, T33.1/ADR-0044) ensures the
      read-model the same way every other CLI command does.

  Both then run the IDENTICAL transport hygiene this module owns — bring the app
  up with logging muted, redirect every `:logger` handler off stdout, restore the
  level — and hand off to the one pure protocol core, `Kazi.MCP.Server.serve/1`.

  ## Why the logging dance

  stdout is the MCP transport — it must carry ONLY line-delimited JSON-RPC, so NO
  log line may land there. Two sources print to stdout by default: the app's own
  runtime logs, and the Phoenix/endpoint boot logs during `app.start`. We handle
  both:

    1. MUTE logging across the boot (`level: :none`) so a boot log never reaches
       the as-yet-unredirected default handler on stdout;
    2. after boot, REDIRECT every `:logger` handler that writes to `:standard_io`
       over to `:standard_error`, then restore the previous level — so all
       subsequent runtime logging (a tool call's warnings, etc.) goes to stderr
       and the JSON-RPC stream on stdout stays clean.
  """

  @doc """
  Boot the read-model with logging muted, redirect logging off stdout, then pump
  `Kazi.MCP.Server.serve/1` until EOF on stdin.

  Options (all optional):

    * `:boot` — a 0-arity function run (with logging muted) to bring `:kazi` up,
      or `false` to skip booting entirely. `mix kazi.mcp` passes
      `fn -> Mix.Task.run("app.start") end`; the CLI verb passes its
      read-model bootstrap. A caller whose app is ALREADY running (a test) passes
      `boot: false`.
    * `:redirect_logging` — `true` (default) runs the mute/redirect/restore
      dance; `false` leaves `:logger` untouched (a test that must not mutate the
      global logger). When `false`, `:boot` still runs (un-muted).

  Every other option is forwarded verbatim to `Kazi.MCP.Server.serve/1` (e.g.
  `:device`, and the injection seams a hermetic caller threads).
  """
  @spec serve(keyword()) :: :ok
  def serve(opts \\ []) do
    {boot, opts} = Keyword.pop(opts, :boot, false)
    {redirect?, serve_opts} = Keyword.pop(opts, :redirect_logging, true)

    boot_with_clean_stdout(boot, redirect?)

    Kazi.MCP.Server.serve(serve_opts)
  end

  # Run the boot fn and keep stdout clean for the JSON-RPC stream. With
  # `redirect? == true` we mute logging across the boot, point every stdout
  # handler at stderr, and restore the prior level; with `false` we only run the
  # boot (the caller manages logging — e.g. a test that must not touch :logger).
  defp boot_with_clean_stdout(boot, true) do
    previous_level = Logger.level()
    Logger.configure(level: :none)

    run_boot(boot)

    redirect_logging_to_stderr()
    Logger.configure(level: previous_level)
    :ok
  end

  defp boot_with_clean_stdout(boot, false), do: run_boot(boot)

  defp run_boot(false), do: :ok

  defp run_boot(fun) when is_function(fun, 0) do
    _ = fun.()
    :ok
  end

  # Point every `:logger` handler that writes to `:standard_io` at
  # `:standard_error` instead, so no log line lands on stdout (the MCP transport).
  # `:logger` forbids changing a live handler's `type` in place
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

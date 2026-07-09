defmodule Kazi.Logging.StderrRedirect do
  @moduledoc """
  Point every `:logger` handler that writes to `:standard_io` at
  `:standard_error` instead, so no log line lands on stdout.

  Two machine surfaces depend on a byte-clean stdout and share this helper:

    * the MCP stdio transport (`Kazi.MCP.Stdio`) — stdout carries ONLY
      line-delimited JSON-RPC;
    * `--json` CLI runs (`Kazi.CLI`, issue #804 / T39.4, ADR-0049 decision 4) —
      stdout carries exactly one JSON object (JSONL under `--stream`).

  `config/config.exs` already routes the DEFAULT handler to stderr on every
  entrypoint (release, escript, `mix run`), so calling this is defense in
  depth: it restores the invariant even when the surrounding environment (a
  dev logger config, an operator override, a dependency's logger setup)
  pointed a handler back at stdout after boot.
  """

  @doc """
  Redirect every stdout-writing `:logger` handler to stderr. Idempotent: a
  handler already on `:standard_error` (the shipped config default) is left
  untouched, and non-stdio handlers (files, custom modules) are never touched.

  `:logger` forbids changing a live handler's `type` in place
  (`:illegal_config_change`), so each `:standard_io` handler is removed and
  re-added with the same module/config but `type: :standard_error`.
  Best-effort: a handler that does not re-add cleanly is left as-is (logging
  still works, on stdout).
  """
  @spec redirect() :: :ok
  def redirect do
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

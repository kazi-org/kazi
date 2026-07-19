defmodule Kazi.Metric do
  @moduledoc """
  Runs a declared command in a workspace and extracts a single numeric SIGNAL —
  the scalar a `:ratchet` predicate compares against its baseline (T32.3,
  ADR-0041 decision 4).

  A metric is the dense half of envelope v2: most checkers already compute a
  scalar (coverage %, binary size, mutation 0.82, an axe-violation count) — the
  metric is how a goal declares "run THIS and read THAT number" so the ratchet
  machinery (`Kazi.Ratchet`) stays metric-agnostic and the SAME mode services
  coverage, perf, and size.

  ## Config

  The metric map carries the command and how to read the number off its output:

    * `:cmd`  — the executable (string). Required. ONE executable, not a command
      line (`cmd: "scripts/coverage"`, not `cmd: "scripts/coverage --json"`); use
      `:args` (mirrors `Kazi.Providers.CustomScript`, lore L-0012).
    * `:args` — argument list (list of strings). Optional, defaults to `[]`.
    * `:env`  — extra environment, a `{name, value}` list or a `{name => value}`
      map. Optional.
    * `:path` — a `Kazi.JSONPath` subset over the command's JSON stdout
      (`$.totals.percent`, `$.runs[0].results`). Optional: ABSENT means stdout is
      parsed directly as a number (a tool that prints just `"812345"`); PRESENT
      means stdout is decoded as JSON and the value at `:path` is read (a list
      uses its length, so a findings array yields its COUNT).
    * `:timeout_ms` — kill the command after this many ms and report `:error`
      (the metric did not complete). Optional; absent means no timeout.

  ## Result

  `signal/2` returns `{:ok, number, output}` (the extracted signal plus the raw,
  untruncated stdout, so the caller can attach truncated evidence) or
  `{:error, reason}`. A missing binary, a non-zero metric exit, a JSON parse
  failure, an unresolved path, or a non-numeric value is an `:error` — a ratchet
  must never read a broken metric as a passing signal.
  """

  @typedoc "A metric config map (atom keys)."
  @type config :: map()

  @doc """
  Runs the metric command in `workspace` and extracts the numeric signal.

  Returns `{:ok, number, raw_output}` or `{:error, reason}`.
  """
  @spec signal(config(), Path.t()) :: {:ok, number(), String.t()} | {:error, term()}
  def signal(config, workspace) when is_map(config) do
    with {:ok, cmd, args} <- fetch_cmd(config),
         {:ran, output, 0} <- run(cmd, args, workspace, config) do
      extract(output, config)
    else
      {:ran, output, exit_code} -> {:error, {:metric_exit, exit_code, truncate(output)}}
      {:raised, message} -> {:error, {:metric_unrunnable, message}}
      {:timeout, ms} -> {:error, {:metric_timeout_ms, ms}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Pull the number off stdout: with a :path, decode JSON and read it through the
  # shared JSONPath subset; without one, parse the whole (trimmed) stdout as a
  # number. Either way a non-number is an :error (never a silent zero).
  defp extract(output, config) do
    case Map.get(config, :path) do
      path when is_binary(path) and path != "" ->
        with {:ok, data} <- decode_json(output),
             {:ok, raw} <- Kazi.JSONPath.get(data, path) do
          Kazi.JSONPath.to_number(raw)
          |> tag_output(output)
        end

      nil ->
        parse_scalar(output) |> tag_output(output)

      other ->
        {:error, {:invalid_metric_path, other}}
    end
  end

  defp tag_output({:ok, number}, output), do: {:ok, number, output}
  defp tag_output({:error, reason}, _output), do: {:error, reason}

  # Parse the whole stdout as a single number (a tool that prints just the value).
  defp parse_scalar(output) do
    trimmed = String.trim(output)

    case Float.parse(trimmed) do
      {number, ""} -> {:ok, number}
      _ -> {:error, {:metric_not_a_number, truncate(trimmed)}}
    end
  end

  defp fetch_cmd(config) do
    case config[:cmd] do
      cmd when is_binary(cmd) and cmd != "" -> {:ok, cmd, List.wrap(config[:args] || [])}
      nil -> {:error, :missing_metric_cmd}
      other -> {:error, {:invalid_metric_cmd, other}}
    end
  end

  # Run the command in the workspace via the shared command-execution core (the
  # same `:error` vs ran-exit boundary the custom_script/test_runner/prod_log
  # providers fold onto, T32.1b/ADR-0040). A raise (missing binary / bad cwd) or a
  # timeout overrun comes back tagged for `signal/2` to map to `:error`.
  defp run(cmd, args, workspace, config) do
    opts = [cd: workspace, stderr_to_stdout: false] ++ env_opt(config)
    Kazi.Providers.CommandRunner.run(cmd, args, opts, Map.get(config, :timeout_ms))
  end

  defp decode_json(output) do
    case Jason.decode(output) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, :metric_invalid_json}
    end
  end

  defp env_opt(config) do
    case Map.get(config, :env) do
      list when is_list(list) -> [env: normalize_env(list)]
      map when is_map(map) -> [env: normalize_env(Map.to_list(map))]
      _ -> []
    end
  end

  defp normalize_env(pairs) do
    Enum.map(pairs, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp truncate(output) when is_binary(output) do
    if String.length(output) > 500,
      do: String.slice(output, 0, 500) <> "…[truncated]",
      else: output
  end

  defp truncate(other), do: other
end

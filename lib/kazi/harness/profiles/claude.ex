defmodule Kazi.Harness.Profiles.Claude do
  @moduledoc """
  The built-in `:claude` harness profile logic (ADR-0016): the argv assembly and
  JSON-envelope parsing for `claude -p --output-format json`, factored out of
  `Kazi.Harness.ClaudeAdapter` so the generic `Kazi.Harness.CliAdapter` (T8.2) can
  drive Claude through the same path as any other harness.

  This module is the **canonical** home of the Claude-specific boundary logic. It
  reproduces `Kazi.Harness.ClaudeAdapter`'s behaviour byte-for-byte (pinned by a
  golden test that drives the real adapter against the argv/JSON stub binaries);
  T8.3 then makes `ClaudeAdapter` a thin shim delegating here, removing the
  duplication. Until then the two are kept in lock-step by that golden test.

  Both functions are PURE: `build_args/2` renders the args after the `claude`
  command, `parse/1` turns stdout into the additive structured subset of the
  result map. Neither shells out — `System.cmd` lives in the CliAdapter.
  """

  # =============================================================================
  # argv assembly (mirrors ClaudeAdapter.run/3's args, T4.1 + T4.8)
  # =============================================================================

  @doc """
  Renders the args AFTER the `claude` command for `prompt`/`opts`.

  `-p <prompt> --output-format json` is the always-present non-interactive +
  structured-envelope shape (ADR-0008, T4.1). The claw-code hygiene flags (T4.8),
  the in-family model selector (T19.6, ADR-0033), and the inner-harness economy
  flags (T36.1, ADR-0047) are appended ONLY when their opt is supplied, so with no
  such opts the argv is byte-for-byte the pre-T4.8 shape:

    * `:max_budget_usd` -> `--max-budget-usd <amount>`  (per-dispatch ceiling)
    * `:allowed_tools`  -> `--allowed-tools <t> <t> …`  (least-privilege tool set)
    * `:permission_mode`-> `--permission-mode <mode>`   (least-privilege mode)
    * `:model`          -> `--model <m>`                (in-family Claude tiering)

  `--model <m>` (ADR-0033) selects a CHEAPER in-family Claude model (e.g.
  Haiku/Sonnet) so a frontier Claude can author the predicates once and kazi
  drives the grind on a cheap Claude model — NO local model required. It is
  appended ONLY when `opts[:model]` is a non-empty string; when absent, the argv
  is byte-for-byte what it was before this flag existed.

  The economy flags (ADR-0047) shrink what the inner harness sees per dispatch —
  fewer tool schemas in context, a narrower MCP surface, a turn ceiling. Each is
  appended ONLY when its opt is supplied, AFTER the hygiene + model args, so with
  none of them the argv is byte-for-byte unchanged. See `economy_args/1` for the
  opt → flag map and the version-gated capability check.
  """
  @spec build_args(String.t(), keyword()) :: [String.t()]
  def build_args(prompt, opts) when is_binary(prompt) and is_list(opts) do
    ["-p", prompt, "--output-format", "json"] ++
      hygiene_args(opts) ++ model_args(opts) ++ economy_args(opts)
  end

  defp hygiene_args(opts) do
    budget_args(opts) ++ allowed_tools_args(opts) ++ permission_mode_args(opts)
  end

  defp model_args(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" -> ["--model", model]
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # economy flags (T36.1, ADR-0047): the inner-harness minimalism surface.
  # ---------------------------------------------------------------------------

  # The opt -> `claude` flag map, in stable emission order. `kind` decides how the
  # value renders:
  #
  #   * `:list`    -> `<flag> <v> <v> …`  (tool/config lists; accepts a list or a
  #                   comma/space-delimited string, normalized the same way the
  #                   T4.8 `--allowed-tools` set is)
  #   * `:value`   -> `<flag> <v>`        (a single scalar, e.g. the turn ceiling)
  #   * `:boolean` -> `<flag>`            (a bare switch, emitted only when truthy)
  #
  # `min_version` is the Claude Code version a flag's behavior depends on; nil means
  # no gate. `--strict-mcp-config` and `--exclude-dynamic-system-prompt-sections`
  # are version-sensitive (ADR-0047 risk note), so they carry a conservative floor:
  # on a CLI older than that, the flag is DROPPED rather than emitted to a binary
  # that would error on it. When `opts[:cli_version]` is absent (kazi could not
  # probe the binary) the check is permissive — it emits the flag, matching the
  # pre-T36.1 behavior of never second-guessing the installed CLI.
  @economy_flags [
    %{opt: :tools, flag: "--tools", kind: :list, min_version: nil},
    %{opt: :disallowed_tools, flag: "--disallowedTools", kind: :list, min_version: nil},
    %{opt: :mcp_config, flag: "--mcp-config", kind: :list, min_version: nil},
    %{opt: :strict_mcp_config, flag: "--strict-mcp-config", kind: :boolean, min_version: "1.0.0"},
    %{opt: :max_turns, flag: "--max-turns", kind: :value, min_version: nil},
    %{
      opt: :exclude_dynamic_system_prompt_sections,
      flag: "--exclude-dynamic-system-prompt-sections",
      kind: :boolean,
      min_version: "1.0.0"
    },
    %{
      opt: :no_session_persistence,
      flag: "--no-session-persistence",
      kind: :boolean,
      min_version: nil
    }
  ]

  @spec economy_args(keyword()) :: [String.t()]
  defp economy_args(opts) do
    cli_version = Keyword.get(opts, :cli_version)
    Enum.flat_map(@economy_flags, &flag_args(&1, opts, cli_version))
  end

  # One flag's contribution: nothing when the opt is absent/empty or the running
  # CLI is too old to understand it; otherwise the rendered flag + value(s).
  @spec flag_args(map(), keyword(), term()) :: [String.t()]
  defp flag_args(%{min_version: min} = spec, opts, cli_version) do
    if cli_supports?(min, cli_version) do
      render_flag(spec, Keyword.get(opts, spec.opt))
    else
      []
    end
  end

  defp render_flag(%{kind: :boolean, flag: flag}, true), do: [flag]
  defp render_flag(%{kind: :boolean}, _value), do: []

  defp render_flag(%{kind: :value, flag: flag}, value)
       when is_integer(value) and value > 0,
       do: [flag, Integer.to_string(value)]

  defp render_flag(%{kind: :value, flag: flag}, value)
       when is_binary(value) and value != "",
       do: [flag, value]

  defp render_flag(%{kind: :value}, _value), do: []

  defp render_flag(%{kind: :list, flag: flag}, value) do
    case normalize_tools(value) do
      [] -> []
      items -> [flag | items]
    end
  end

  # The version-gated capability check. No floor, or no detected version, means
  # "emit" (permissive). An unparseable version on either side also degrades to
  # permissive — kazi never withholds a flag because it failed to read a version.
  @spec cli_supports?(String.t() | nil, term()) :: boolean()
  defp cli_supports?(nil, _cli_version), do: true
  defp cli_supports?(_min_version, nil), do: true

  defp cli_supports?(min_version, cli_version) when is_binary(cli_version) do
    with {:ok, have} <- Version.parse(cli_version),
         {:ok, need} <- Version.parse(min_version) do
      Version.compare(have, need) != :lt
    else
      _ -> true
    end
  end

  defp cli_supports?(_min_version, _cli_version), do: true

  defp budget_args(opts) do
    case Keyword.get(opts, :max_budget_usd) do
      nil -> []
      amount when is_number(amount) and amount > 0 -> ["--max-budget-usd", to_string(amount)]
      _ -> []
    end
  end

  defp allowed_tools_args(opts) do
    case normalize_tools(Keyword.get(opts, :allowed_tools)) do
      [] -> []
      tools -> ["--allowed-tools" | tools]
    end
  end

  defp permission_mode_args(opts) do
    case Keyword.get(opts, :permission_mode) do
      nil -> []
      mode when is_atom(mode) -> ["--permission-mode", Atom.to_string(mode)]
      mode when is_binary(mode) and mode != "" -> ["--permission-mode", mode]
      _ -> []
    end
  end

  @spec normalize_tools(term()) :: [String.t()]
  defp normalize_tools(nil), do: []

  defp normalize_tools(tools) when is_list(tools) do
    tools
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_tools(tools) when is_binary(tools) do
    tools
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_tools(_other), do: []

  # =============================================================================
  # JSON envelope parsing (mirrors ClaudeAdapter.parse_envelope/1, T4.1)
  # =============================================================================

  @doc """
  Parses the `claude --output-format json` envelope into the additive subset of
  the result map. Best-effort and total: anything other than a JSON OBJECT yields
  `%{}`, so the caller keeps its back-compat base map and never crashes on a
  surprising harness.

  Recognised fields: `result` (final text), `usage` (summed to a token total,
  surfaced as `:tokens` and `:cost => %{tokens: n}`), `total_cost_usd`
  (`:cost_usd`), and a touched working set (`:touched`).
  """
  @spec parse(String.t()) :: map()
  def parse(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, %{} = envelope} -> extract_fields(envelope)
      _ -> %{}
    end
  end

  defp extract_fields(envelope) do
    %{}
    |> put_result(envelope)
    |> put_tokens(envelope)
    |> put_cost(envelope)
    |> put_touched(envelope)
  end

  defp put_result(acc, %{"result" => result}) when is_binary(result),
    do: Map.put(acc, :result, result)

  defp put_result(acc, _envelope), do: acc

  defp put_tokens(acc, %{"usage" => %{} = usage}) do
    case total_tokens(usage) do
      0 -> acc
      total -> acc |> Map.put(:tokens, total) |> Map.put(:cost, %{tokens: total})
    end
  end

  defp put_tokens(acc, _envelope), do: acc

  defp put_cost(acc, %{"total_cost_usd" => cost}) when is_number(cost),
    do: Map.put(acc, :cost_usd, cost)

  defp put_cost(acc, _envelope), do: acc

  defp put_touched(acc, envelope) do
    case touched_files(envelope) do
      [] -> acc
      files -> Map.put(acc, :touched, files)
    end
  end

  @spec total_tokens(map()) :: non_neg_integer()
  defp total_tokens(usage) do
    [
      "input_tokens",
      "output_tokens",
      "cache_creation_input_tokens",
      "cache_read_input_tokens"
    ]
    |> Enum.reduce(0, fn key, sum ->
      case Map.get(usage, key) do
        n when is_integer(n) and n >= 0 -> sum + n
        _ -> sum
      end
    end)
  end

  @spec touched_files(map()) :: [String.t()]
  defp touched_files(envelope) do
    ["touched", "touched_files", "files", "working_set"]
    |> Enum.find_value([], fn key ->
      case Map.get(envelope, key) do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> nil
      end
    end)
  end
end

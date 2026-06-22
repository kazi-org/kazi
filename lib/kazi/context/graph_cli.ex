defmodule Kazi.Context.GraphCli do
  @moduledoc """
  The real `code-review-graph` query used by `Kazi.Context.RepoMapSource` when a
  target has a graph (T4.2, ADR-0010). It shells out to the `code-review-graph`
  CLI in the workspace and parses its JSON into a `Kazi.Context.Survey`.

  This is the live-MCP / subprocess boundary, so it is **injected** behind
  `RepoMapSource`'s `:graph_cli` opt and never invoked by the hermetic suite —
  tests pass a pure double. The contract is `survey/3 -> {:ok, Survey} | {:error,
  reason}`; any error degrades to the repo-map fallback rather than failing the
  orientation (ADR-0010's hybrid).

  ## Determinism

  The CLI is asked for structure, not source, and the result is fully re-sorted by
  `Kazi.Context` before it reaches a prompt, so a graph that returns the same
  *content* yields a byte-identical pack. We pass `--deterministic` when the CLI
  supports it and never include timestamps in the parsed survey.

  ## Command

  Resolution order for the executable: `opts[:graph_command]` > app config
  `config :kazi, Kazi.Context.GraphCli, command: ...` > the default
  `"code-review-graph"`.
  """

  @behaviour Kazi.Context.GraphSource

  alias Kazi.Context.{FileRef, Survey, Symbol}

  @default_command "code-review-graph"

  @impl true
  def survey(workspace, evidence_terms, opts \\ [])
      when is_binary(workspace) and is_list(evidence_terms) and is_list(opts) do
    command = command(opts)
    args = query_args(evidence_terms)

    try do
      case System.cmd(command, args, cd: workspace, stderr_to_stdout: true) do
        {output, 0} -> parse(output)
        {output, _nonzero} -> {:error, {:graph_cli_failed, String.trim(output)}}
      end
    rescue
      error in ErlangError ->
        case error.original do
          :enoent -> {:error, {:command_not_found, command}}
          other -> {:error, other}
        end
    end
  end

  # `query_graph` over the impacted set, asking for the JSON the graph emits for a
  # structural survey: impacted files, their symbols, and one hop of call edges.
  defp query_args(evidence_terms) do
    ["query-graph", "--format", "json", "--impacted", Enum.join(evidence_terms, ",")]
  end

  # Parses the graph's JSON into a Survey. We keep parsing total: a shape we do not
  # recognise is an :error (-> repo-map fallback), never a crash.
  defp parse(output) do
    with {:ok, %{} = json} <- decode(output) do
      files = json |> Map.get("files", []) |> Enum.map(&parse_file/1) |> drop_nils()
      symbols = json |> Map.get("symbols", []) |> Enum.map(&parse_symbol/1) |> drop_nils()
      tests = json |> Map.get("test_sources", []) |> Enum.map(&parse_test_source/1) |> drop_nils()

      {:ok, Survey.new(:graph, files: files, symbols: symbols, test_sources: tests)}
    end
  end

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, %{} = json} -> {:ok, json}
      {:ok, _other} -> {:error, :unexpected_graph_json}
      {:error, _} = err -> err
    end
  end

  defp parse_file(%{"path" => path}) when is_binary(path), do: FileRef.new(path)
  defp parse_file(_), do: nil

  defp parse_symbol(%{"name" => name, "path" => path} = sym)
       when is_binary(name) and is_binary(path) do
    Symbol.new(name, path,
      kind: parse_kind(Map.get(sym, "kind")),
      callers: string_list(Map.get(sym, "callers", [])),
      callees: string_list(Map.get(sym, "callees", []))
    )
  end

  defp parse_symbol(_), do: nil

  defp parse_test_source(%{"path" => path} = ts) when is_binary(path) do
    FileRef.new(path, source: Map.get(ts, "source"))
  end

  defp parse_test_source(_), do: nil

  defp parse_kind("function"), do: :function
  defp parse_kind("module"), do: :module
  defp parse_kind("type"), do: :type
  defp parse_kind(_), do: :other

  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_), do: []

  defp drop_nils(list), do: Enum.reject(list, &is_nil/1)

  defp command(opts) do
    Keyword.get(opts, :graph_command) ||
      Application.get_env(:kazi, __MODULE__, [])[:command] ||
      @default_command
  end
end

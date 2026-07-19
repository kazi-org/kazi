defmodule Kazi.Context.StaticGraphSource do
  @moduledoc """
  A pure, hermetic `Kazi.Context.GraphSource` double for tests: it returns a
  pre-built `Kazi.Context.Survey` (or one assembled from simple file/symbol opts)
  and touches neither the filesystem nor the network — exactly the seam ADR-0010's
  "hermetic, no live MCP call" acceptance criterion requires.

  This lives only in `test/` (zero-stub policy: no doubles in `lib/`). It lets the
  `Kazi.Context` ranking/budget/determinism tests drive the graph-present path
  without a real graph, and the repo-map path is covered separately by a Tier-2
  test over a temp fixture repo using the real `Kazi.Context.RepoMapSource`.

  ## Usage

      source = Kazi.Context.StaticGraphSource.new(
        origin: :graph,
        files: ["lib/a.ex", "lib/b.ex"],
        symbols: [{"f/1", "lib/a.ex", callers: ["g/0"]}]
      )

      Kazi.Context.orientation_pack(failing, "/ws", graph_source: source)

  `source` is a `{module, opts}` tuple, which `Kazi.Context` accepts directly.
  """

  @behaviour Kazi.Context.GraphSource

  alias Kazi.Context.{FileRef, Survey, Symbol}

  @doc """
  Builds the `{module, opts}` tuple to pass as `:graph_source`. Accepts either a
  ready `:survey`, or `:files` / `:symbols` / `:test_sources` shorthands.
  """
  @spec new(keyword()) :: {module(), keyword()}
  def new(opts \\ []), do: {__MODULE__, opts}

  @impl true
  def survey(_workspace, _evidence_terms, opts) do
    case Keyword.get(opts, :survey) do
      %Survey{} = survey -> survey
      nil -> build(opts)
    end
  end

  defp build(opts) do
    Survey.new(Keyword.get(opts, :origin, :graph),
      files: opts |> Keyword.get(:files, []) |> Enum.map(&to_file/1),
      symbols: opts |> Keyword.get(:symbols, []) |> Enum.map(&to_symbol/1),
      test_sources: opts |> Keyword.get(:test_sources, []) |> Enum.map(&to_file/1)
    )
  end

  defp to_file(path) when is_binary(path), do: FileRef.new(path)
  defp to_file({path, file_opts}) when is_binary(path), do: FileRef.new(path, file_opts)

  defp to_symbol({name, path}), do: Symbol.new(name, path)
  defp to_symbol({name, path, sym_opts}), do: Symbol.new(name, path, sym_opts)
end

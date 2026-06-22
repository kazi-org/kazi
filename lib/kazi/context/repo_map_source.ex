defmodule Kazi.Context.RepoMapSource do
  @moduledoc """
  The real default `Kazi.Context.GraphSource` (T4.2, ADR-0010): the "graph when
  present, else tree-sitter repo map" decision point.

  When the target has a `code-review-graph` (`.code-review-graph/graph.db`), this
  derives impacted files/symbols and caller/callee edges from the graph. When it
  does not — or the graph CLI is unavailable — it falls back to a pragmatic,
  dependency-free **file-scan repo map**: it walks the workspace's source files,
  reads symbol definitions with line-level regexes, and ranks by relevance to the
  evidence terms. ADR-0010 prescribes a tree-sitter repo map here; an Elixir
  tree-sitter binding is not a current dependency, so the file-scan map is the
  minimal real substitute (no heavy dep without an ADR). The graph remains the
  preferred source whenever it is present.

  This source is deterministic — it sorts what it discovers and never reads a
  clock — so the pack built from it is a stable, cacheable prompt prefix. It is
  **not** exercised in the hermetic test suite (tests inject a pure double); the
  filesystem-boundary behavior is covered by Tier-2 tests over a temp fixture
  repo.

  ## Options

    * `:graph_cli` — module implementing the graph query (defaults to
      `Kazi.Context.GraphCli`); injected so the graph path can be exercised
      without a live MCP server.
    * `:max_files` — cap on scanned/returned files (default `200`) so a huge tree
      cannot blow up a survey before the token budget even applies.
    * `:source_extensions` — file extensions treated as source (default Elixir +
      common languages).
  """

  @behaviour Kazi.Context.GraphSource

  alias Kazi.Context.{FileRef, GraphCli, Survey, Symbol}

  @default_max_files 200
  @default_extensions ~w(.ex .exs .erl .heex .ts .tsx .js .jsx .py .go .rb .rs)
  @graph_db_relpath ".code-review-graph/graph.db"

  @impl true
  def survey(workspace, evidence_terms, opts \\ [])
      when is_binary(workspace) and is_list(evidence_terms) and is_list(opts) do
    if graph_present?(workspace) do
      graph_cli = Keyword.get(opts, :graph_cli, GraphCli)

      case graph_cli.survey(workspace, evidence_terms, opts) do
        {:ok, %Survey{} = survey} -> survey
        # The graph exists but the CLI could not answer (missing binary, parse
        # error): fall back rather than fail the orientation. ADR-0010's hybrid is
        # explicit that a graph miss degrades to the repo map, never to a crash.
        _ -> repo_map(workspace, evidence_terms, opts)
      end
    else
      repo_map(workspace, evidence_terms, opts)
    end
  end

  @doc "Workspace-relative path of the code-review-graph database, if present."
  @spec graph_db_relpath() :: String.t()
  def graph_db_relpath, do: @graph_db_relpath

  defp graph_present?(workspace) do
    workspace |> Path.join(@graph_db_relpath) |> File.regular?()
  end

  # --- file-scan repo map (the fallback) ---------------------------------------

  defp repo_map(workspace, evidence_terms, opts) do
    max_files = Keyword.get(opts, :max_files, @default_max_files)
    extensions = Keyword.get(opts, :source_extensions, @default_extensions)

    paths =
      workspace
      |> source_paths(extensions)
      |> Enum.sort()
      |> Enum.take(max_files)

    files = Enum.map(paths, &FileRef.new(&1))

    symbols =
      paths |> Enum.flat_map(&symbols_in(workspace, &1)) |> Enum.sort_by(&{&1.path, &1.name})

    test_sources = test_sources(workspace, paths, evidence_terms)

    Survey.new(:repo_map, files: files, symbols: symbols, test_sources: test_sources)
  end

  # Workspace-relative source paths, skipping VCS, build, and dependency dirs that
  # carry no orientation value (and would otherwise dominate the budget).
  defp source_paths(workspace, extensions) do
    workspace
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, workspace))
    |> Enum.reject(&ignored?/1)
    |> Enum.filter(fn rel -> Path.extname(rel) in extensions end)
  end

  defp ignored?(rel) do
    segments = Path.split(rel)
    Enum.any?(~w(.git _build deps node_modules .elixir_ls cover), &(&1 in segments))
  end

  # A line-level pass for top-level definitions. Tree-sitter would be more
  # precise, but a regex over a handful of `def`/`module` forms is enough to map
  # *where things are* — the structure half of the hybrid — without a new dep.
  defp symbols_in(workspace, rel) do
    case File.read(Path.join(workspace, rel)) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.flat_map(&match_symbols(&1, rel))
        |> Enum.uniq_by(&{&1.name, &1.path})

      _ ->
        []
    end
  end

  @symbol_patterns [
    {~r/^\s*defmodule\s+([A-Za-z0-9_.]+)/, :module},
    {~r/^\s*(?:def|defp)\s+([A-Za-z0-9_?!]+)/, :function},
    {~r/^\s*(?:@type|@typep|@opaque)\s+([A-Za-z0-9_]+)/, :type}
  ]

  defp match_symbols(line, rel) do
    Enum.flat_map(@symbol_patterns, fn {pattern, kind} ->
      case Regex.run(pattern, line) do
        [_, name] -> [Symbol.new(name, rel, kind: kind)]
        _ -> []
      end
    end)
  end

  # Read source for files that look like the failing tests (path mentions a term,
  # or sits under a conventional test dir). Bounded to keep the survey small;
  # ranking/truncation downstream enforce the token budget.
  defp test_sources(workspace, paths, evidence_terms) do
    paths
    |> Enum.filter(&test_file?(&1, evidence_terms))
    |> Enum.sort()
    |> Enum.take(3)
    |> Enum.flat_map(fn rel ->
      case File.read(Path.join(workspace, rel)) do
        {:ok, contents} -> [FileRef.new(rel, source: contents)]
        _ -> []
      end
    end)
  end

  defp test_file?(rel, evidence_terms) do
    looks_like_test = String.contains?(rel, "test") or String.contains?(rel, "_spec")
    mentioned = Enum.any?(evidence_terms, &String.contains?(rel, &1))
    looks_like_test or mentioned
  end
end

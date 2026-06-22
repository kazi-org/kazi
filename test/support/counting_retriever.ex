defmodule Kazi.Retrieval.CountingRetriever do
  @moduledoc """
  A hermetic `Kazi.Retrieval` double that COUNTS its invocations (T4.9c): every
  `retrieve/3` call bumps a per-process counter, so a cache-reuse test can assert
  that a cache hit did NOT re-invoke the retriever (the whole point of the T4.9c
  cache — avoid re-embedding an unchanged target).

  Like `Kazi.Retrieval.StaticRetriever` it returns a fixed snippet list and touches
  no embedding model / index / network. Lives only in `test/` (zero-stub policy).
  The counter is the calling process's dictionary, so tests are isolated.

  ## Usage

      retriever = Kazi.Retrieval.CountingRetriever.new(snippets: ["s"])
      # ... drive cached_retrieve/4 ...
      assert Kazi.Retrieval.CountingRetriever.count() == 1
  """

  @behaviour Kazi.Retrieval

  alias Kazi.Retrieval.Snippet

  @doc """
  Builds the `{module, opts}` tuple to pass as `:retriever`, resetting the
  invocation counter to zero. `:snippets` is the fixed result (coerced like
  `StaticRetriever`).
  """
  @spec new(keyword()) :: {module(), keyword()}
  def new(opts \\ []) do
    Process.put(__MODULE__, 0)
    {__MODULE__, opts}
  end

  @doc "How many times `retrieve/3` has been invoked since the last `new/1`."
  @spec count() :: non_neg_integer()
  def count, do: Process.get(__MODULE__, 0)

  @impl true
  @spec retrieve(
          [{Kazi.Predicate.id(), Kazi.PredicateResult.t()}],
          String.t(),
          keyword()
        ) :: [Snippet.t()]
  def retrieve(_failing, _workspace, opts) do
    Process.put(__MODULE__, Process.get(__MODULE__, 0) + 1)

    opts
    |> Keyword.get(:snippets, [])
    |> Enum.map(&to_snippet/1)
  end

  defp to_snippet(%Snippet{} = snippet), do: snippet
  defp to_snippet(text) when is_binary(text), do: Snippet.new(text)
  defp to_snippet({text}) when is_binary(text), do: Snippet.new(text)

  defp to_snippet({text, snippet_opts}) when is_binary(text) and is_list(snippet_opts),
    do: Snippet.new(text, snippet_opts)
end

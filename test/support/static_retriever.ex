defmodule Kazi.Retrieval.StaticRetriever do
  @moduledoc """
  A pure, hermetic `Kazi.Retrieval` double for tests (T4.9a, ADR-0012): it returns
  a pre-built list of `Kazi.Retrieval.Snippet`s and touches neither an embedding
  model, an index, nor the network — exactly the seam ADR-0012's "hermetic, a stub
  drives the default-path tests" criterion requires.

  This lives only in `test/` (zero-stub policy: no doubles in `lib/`). It drives the
  retrieval-on path so the adapter's optional retrieval section can be exercised
  without the real graphify-embeddings backend (T4.9b). Because its result is fixed
  inline, the same opts always yield the same snippets — the determinism a fixed
  retriever guarantees.

  ## Usage

      retriever =
        Kazi.Retrieval.StaticRetriever.new(
          snippets: [
            {"def build(x), do: x + 1", source: "lib/a.ex:42"},
            {"plain snippet with no source"}
          ]
        )

      Kazi.Harness.ClaudeAdapter.build_prompt(work_item, failing, retriever: retriever)

  `retriever` is a `{module, opts}` tuple, which `Kazi.Retrieval` accepts directly.
  """

  @behaviour Kazi.Retrieval

  alias Kazi.Retrieval.Snippet

  @doc """
  Builds the `{module, opts}` tuple to pass as `:retriever`. Accepts either a ready
  list of `Kazi.Retrieval.Snippet`s under `:snippets`, or `{text, opts}` / `{text}`
  shorthands that are coerced into snippets (so a test can declare its fixture
  inline).
  """
  @spec new(keyword()) :: {module(), keyword()}
  def new(opts \\ []), do: {__MODULE__, opts}

  @impl true
  @spec retrieve(
          [{Kazi.Predicate.id(), Kazi.PredicateResult.t()}],
          String.t(),
          keyword()
        ) :: [Snippet.t()]
  def retrieve(_failing, _workspace, opts) do
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

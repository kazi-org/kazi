defmodule Kazi.Context.Survey do
  @moduledoc """
  The raw, *unranked* orientation material a `Kazi.Context.GraphSource` returns for
  a workspace + evidence terms (T4.2, ADR-0010). `Kazi.Context` ranks and bounds
  it into the final `Kazi.Context.Pack`.

  Keeping survey (raw) and pack (ranked, bounded) separate is what makes the seam
  hermetic and the ranking testable in isolation: a source only has to find files,
  symbols, and test sources; ordering, evidence-relevance ranking, and the token
  budget are `Kazi.Context`'s job.
  """

  alias Kazi.Context.{FileRef, Symbol}

  @typedoc """
    * `:origin` — which source produced this (`:graph` for code-review-graph,
      `:repo_map` for the tree-sitter / file-scan fallback). Recorded so the pack
      can declare its provenance.
    * `:files` — candidate `Kazi.Context.FileRef`s (path-only is fine).
    * `:symbols` — candidate `Kazi.Context.Symbol`s; the repo-map fallback leaves
      caller/callee edges empty.
    * `:test_sources` — `Kazi.Context.FileRef`s carrying the failing test's source
      excerpt (the hybrid's file-read half).
  """
  @type t :: %__MODULE__{
          origin: :graph | :repo_map,
          files: [FileRef.t()],
          symbols: [Symbol.t()],
          test_sources: [FileRef.t()]
        }

  @enforce_keys [:origin]
  defstruct origin: :repo_map, files: [], symbols: [], test_sources: []

  @doc "Builds a survey; all collections default to empty."
  @spec new(:graph | :repo_map, keyword()) :: t()
  def new(origin, opts \\ []) when origin in [:graph, :repo_map] do
    %__MODULE__{
      origin: origin,
      files: Keyword.get(opts, :files, []),
      symbols: Keyword.get(opts, :symbols, []),
      test_sources: Keyword.get(opts, :test_sources, [])
    }
  end
end

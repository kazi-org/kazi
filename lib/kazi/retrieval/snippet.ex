defmodule Kazi.Retrieval.Snippet do
  @moduledoc """
  One retrieved snippet — a single result a `Kazi.Retrieval` backend returns for a
  failing predicate (T4.9a, ADR-0012): a piece of relevant prior context plus a
  reference to where it came from.

  This is the unit of the optional, similarity-based recall augmentation. Unlike
  the deterministic orientation pack (`Kazi.Context.Pack`, ADR-0010) — which is
  *where this work lives* from a hermetic blast-radius survey — a snippet is *what
  a retriever judged relevant*. The shape is intentionally small and backend-
  neutral so the no-op default, a test double, and the real graphify-embeddings
  backend (T4.9b) all speak it without leaking embedding internals into the prompt.

    * `:text` — the snippet body rendered into the prompt section.
    * `:source` — a human-readable reference to where the snippet came from (a
      path, a `path:line`, a symbol). Optional; `nil` when the backend has no
      provenance to attribute (the section then renders the text on its own).
  """

  @typedoc """
    * `:text` — the snippet body.
    * `:source` — provenance reference, or `nil`.
  """
  @type t :: %__MODULE__{text: String.t(), source: String.t() | nil}

  @enforce_keys [:text]
  defstruct text: nil, source: nil

  @doc """
  Builds a snippet from its `text` and an optional `:source` reference.

  ## Examples

      iex> Kazi.Retrieval.Snippet.new("def build(x), do: x + 1", source: "lib/a.ex:42").source
      "lib/a.ex:42"

      iex> Kazi.Retrieval.Snippet.new("orphan text").source
      nil
  """
  @spec new(String.t(), keyword()) :: t()
  def new(text, opts \\ []) when is_binary(text) and is_list(opts) do
    %__MODULE__{text: text, source: Keyword.get(opts, :source)}
  end
end

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

  @doc """
  Serializes a snippet to a JSON-safe map for the SHA-keyed retrieval cache
  (T4.9c, ADR-0012). String keys only — the inverse of `from_serializable/1`,
  which reconstructs an equal struct so a cached snippet reused on a hit is
  identical to one freshly retrieved.

  ## Examples

      iex> Kazi.Retrieval.Snippet.new("t", source: "lib/a.ex") |> Kazi.Retrieval.Snippet.to_serializable()
      %{"text" => "t", "source" => "lib/a.ex"}
  """
  @spec to_serializable(t()) :: map()
  def to_serializable(%__MODULE__{text: text, source: source}) do
    %{"text" => text, "source" => source}
  end

  @doc """
  Reconstructs a snippet from the JSON-safe map `to_serializable/1` produced. The
  round-trip is exact: `from_serializable(to_serializable(s)) == s` for any
  snippet.

  ## Examples

      iex> Kazi.Retrieval.Snippet.from_serializable(%{"text" => "t", "source" => nil})
      %Kazi.Retrieval.Snippet{text: "t", source: nil}
  """
  @spec from_serializable(map()) :: t()
  def from_serializable(%{"text" => text} = map) do
    %__MODULE__{text: text, source: Map.get(map, "source")}
  end
end

defmodule Kazi.ContextStore.Snippet do
  @moduledoc """
  One budget-fitting snippet a `Kazi.ContextStore` backend returns from `search/3`
  (T35.1, ADR-0045): a ranked piece of a heavy text artifact, plus a reference to
  the source label it came from and its byte cost against the budget.

  This is the unit of the **context store** layer — budget-fitted retrieval over
  heavy text artifacts and repeated loop evidence — and is deliberately distinct
  from `Kazi.Retrieval.Snippet` (ADR-0012, embedding recall) and from the structural
  orientation pack (ADR-0010). The store is lexical, not semantic; a snippet here is
  *what a budgeted lexical search returned*, attributed to its `source` label so a
  changed-SHA label (see `Kazi.ContextStore.Labels`) is traceable back to its
  artifact.

    * `:text` — the snippet body rendered into the prompt section.
    * `:source` — the source label the snippet came from (see
      `Kazi.ContextStore.Labels`), or `nil` when the backend has no label to
      attribute.
    * `:bytes` — the byte size of `:text`, the snippet's cost against the search
      budget. Defaults to `byte_size(text)`.
  """

  @typedoc """
    * `:text` — the snippet body.
    * `:source` — source label, or `nil`.
    * `:bytes` — byte cost of `:text` against the budget.
  """
  @type t :: %__MODULE__{text: String.t(), source: String.t() | nil, bytes: non_neg_integer()}

  @enforce_keys [:text]
  defstruct text: nil, source: nil, bytes: 0

  @doc """
  Builds a snippet from its `text`, an optional `:source` label, and an optional
  `:bytes` cost (defaults to `byte_size(text)`).

  ## Examples

      iex> Kazi.ContextStore.Snippet.new("indexed log line", source: "kazi:run:g1:iter:3:test-log").source
      "kazi:run:g1:iter:3:test-log"

      iex> Kazi.ContextStore.Snippet.new("abc").bytes
      3
  """
  @spec new(String.t(), keyword()) :: t()
  def new(text, opts \\ []) when is_binary(text) and is_list(opts) do
    %__MODULE__{
      text: text,
      source: Keyword.get(opts, :source),
      bytes: Keyword.get(opts, :bytes, byte_size(text))
    }
  end

  @doc """
  Serializes a snippet to a JSON-safe map (string keys), the inverse of
  `from_serializable/1`.

  ## Examples

      iex> Kazi.ContextStore.Snippet.new("t", source: "lbl") |> Kazi.ContextStore.Snippet.to_serializable()
      %{"text" => "t", "source" => "lbl", "bytes" => 1}
  """
  @spec to_serializable(t()) :: map()
  def to_serializable(%__MODULE__{text: text, source: source, bytes: bytes}) do
    %{"text" => text, "source" => source, "bytes" => bytes}
  end

  @doc """
  Reconstructs a snippet from its serialized map, the inverse of
  `to_serializable/1`.

  ## Examples

      iex> Kazi.ContextStore.Snippet.from_serializable(%{"text" => "t", "source" => "lbl", "bytes" => 1})
      %Kazi.ContextStore.Snippet{text: "t", source: "lbl", bytes: 1}
  """
  @spec from_serializable(map()) :: t()
  def from_serializable(%{"text" => text} = map) when is_binary(text) do
    %__MODULE__{
      text: text,
      source: Map.get(map, "source"),
      bytes: Map.get(map, "bytes", byte_size(text))
    }
  end
end

defmodule Kazi.ContextStore.NoOp do
  @moduledoc """
  The default `Kazi.ContextStore` backend (T35.1, ADR-0045): the store OFF.

  This is the *off state*, not a placeholder — it is the real default that makes
  ADR-0045's additive-only guarantee hold: with no store injected or configured,
  `index/3` stores nothing and `search/3` returns `{:ok, []}`, so kazi's default
  per-iteration context is byte-identical to the pre-store path and the result
  contract carries no `context_store` object (ADR-0045 §6). The Gist CLI adapter
  (`Kazi.ContextStore.GistCLI`, T35.2) lands behind this same seam; until a goal or
  run opts in with `--context-store gist`, the no-op is what runs.
  """

  @behaviour Kazi.ContextStore

  alias Kazi.ContextStore.{Labels, Snippet}

  @impl true
  @spec index(Labels.label(), String.t(), keyword()) ::
          {:ok, Kazi.ContextStore.index_result()}
  def index(label, content, _opts) when is_binary(label) and is_binary(content) do
    # Report the label and byte count so callers can keep their bookkeeping
    # uniform, but store nothing: the off state indexes no bytes.
    {:ok, %{label: label, bytes: byte_size(content), checksum: nil}}
  end

  @impl true
  @spec search(String.t(), non_neg_integer(), keyword()) :: {:ok, [Snippet.t()]}
  def search(_query, _budget, _opts), do: {:ok, []}

  @impl true
  @spec stats(keyword()) :: {:ok, Kazi.ContextStore.stats_map()}
  def stats(_opts) do
    {:ok, %{provider: :none, indexed_bytes: 0, returned_bytes: 0, saved_bytes: 0}}
  end
end

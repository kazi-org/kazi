defmodule Kazi.Context.FileRef do
  @moduledoc """
  One ranked file in an orientation pack (T4.2, ADR-0010): a workspace-relative
  path plus an optional bounded source excerpt.

  Most files in a pack are referenced by path only (cheap map memory — *where
  things are*). The failing test's file additionally carries a `:source` excerpt,
  since the source itself is what the agent needs and the graph abstraction omits
  source lines (the hybrid: structure from the graph, source from the file).
  """

  @typedoc """
    * `:path` — workspace-relative path.
    * `:source` — optional source excerpt (e.g. the failing test body); `nil` for
      path-only references.
  """
  @type t :: %__MODULE__{path: String.t(), source: String.t() | nil}

  @enforce_keys [:path]
  defstruct path: nil, source: nil

  @doc """
  Builds a file reference.

  ## Examples

      iex> Kazi.Context.FileRef.new("lib/a.ex").source
      nil
  """
  @spec new(String.t(), keyword()) :: t()
  def new(path, opts \\ []) when is_binary(path) do
    %__MODULE__{path: path, source: Keyword.get(opts, :source)}
  end
end

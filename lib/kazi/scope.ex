defmodule Kazi.Scope do
  @moduledoc """
  The repo and paths a goal's agents may touch (ADR-0002, concept §4).

  Scope bounds *where* fixer agents may edit. In Slice 0 it identifies the target
  workspace (a local repo path / the `--workspace` arg of `kazi run`, T0.10) and
  optionally narrows the editable paths. Later slices use the path set to seed
  blast-radius leases (ADR-0006).
  """

  @type t :: %__MODULE__{
          workspace: String.t() | nil,
          repo: String.t() | nil,
          paths: [String.t()]
        }

  defstruct workspace: nil,
            repo: nil,
            paths: []

  @doc """
  Builds a scope.

  ## Examples

      iex> Kazi.Scope.new(workspace: "/tmp/repo", paths: ["lib/"]).paths
      ["lib/"]
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      workspace: Keyword.get(opts, :workspace),
      repo: Keyword.get(opts, :repo),
      paths: Keyword.get(opts, :paths, [])
    }
  end
end

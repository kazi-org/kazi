defmodule Kazi.ReadModel.MemoryIndexFile do
  @moduledoc """
  One row of the content-hash ledger `Kazi.Memory.SemanticIndex` uses to make
  corpus indexing incremental (ADR-0062 decision 2): the sha256 `content_hash`
  a corpus file's `path` was last chunked at, scoped to the `workspace_root`
  it was indexed from (issue #977 — a bare `path` collides across workspaces
  sharing one read-model, e.g. two repos both having a "CLAUDE.md").

  Rebuildable projection — authoritative for nothing; the corpus markdown IS
  the truth (ADR-0060 guardrail 1).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "memory_index_files" do
    field(:workspace_root, :string)
    field(:path, :string)
    field(:content_hash, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:workspace_root, :path, :content_hash]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> unique_constraint([:workspace_root, :path],
      name: :memory_index_files_workspace_root_path_index
    )
  end
end

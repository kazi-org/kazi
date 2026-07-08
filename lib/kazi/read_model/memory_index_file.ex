defmodule Kazi.ReadModel.MemoryIndexFile do
  @moduledoc """
  One row of the content-hash ledger `Kazi.Memory.SemanticIndex` uses to make
  corpus indexing incremental (ADR-0062 decision 2): the sha256 `content_hash`
  a corpus file's `path` was last chunked at. A refresh re-chunks a file only
  when its current on-disk hash no longer matches this row.

  Rebuildable projection — authoritative for nothing; the corpus markdown IS
  the truth (ADR-0060 guardrail 1).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "memory_index_files" do
    field(:path, :string)
    field(:content_hash, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:path, :content_hash]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> unique_constraint(:path, name: :memory_index_files_path_index)
  end
end

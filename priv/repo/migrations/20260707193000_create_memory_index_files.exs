defmodule Kazi.Repo.Migrations.CreateMemoryIndexFiles do
  @moduledoc """
  ADR-0062 (semantic memory): the content-hash ledger that makes corpus
  indexing INCREMENTAL. One row per indexed corpus file (`path`, relative to
  the workspace it was indexed from) carrying the sha256 `content_hash` it was
  last chunked at. `Kazi.Memory.SemanticIndex.refresh/2` re-chunks a file only
  when its current on-disk hash differs from the stored one, so an unchanged
  file is never re-indexed.

  Rebuildable projection like the rest of the read-model (concept §7):
  authoritative for nothing (the corpus markdown IS the truth, ADR-0060
  guardrail 1) — dropping this table just forces a full re-index on next
  recall, not a knowledge loss.
  """

  use Ecto.Migration

  def change do
    create table(:memory_index_files) do
      add :path, :string, null: false
      add :content_hash, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memory_index_files, [:path])
  end
end

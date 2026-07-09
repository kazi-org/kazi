defmodule Kazi.Repo.Migrations.AddWorkspaceRootToMemoryChunksFts do
  @moduledoc """
  Issue #977: mirrors the `workspace_root` scoping added to
  `memory_index_files` (see the sibling migration) onto `memory_chunks_fts`,
  so a chunk indexed under one workspace's relative `path` is never returned
  for another workspace's recall against the same relative path.

  `memory_chunks_fts` is a rebuildable projection (ADR-0062 decision 1: the
  corpus markdown is the source of truth), and FTS5 virtual tables have no
  `ALTER TABLE ... ADD COLUMN` support in the SQLite build this stack ships —
  so, like the table's original creation, this is raw SQL: drop and recreate
  with the new `workspace_root UNINDEXED` column. Dropping loses only cached
  chunks, never corpus content; `SemanticIndex.refresh/2` rebuilds them from
  the on-disk markdown on the next recall.
  """

  use Ecto.Migration

  def up do
    execute "DROP TABLE IF EXISTS memory_chunks_fts"

    execute """
    CREATE VIRTUAL TABLE memory_chunks_fts USING fts5(
      workspace_root UNINDEXED,
      path UNINDEXED,
      heading UNINDEXED,
      line_start UNINDEXED,
      line_end UNINDEXED,
      body
    )
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS memory_chunks_fts"

    execute """
    CREATE VIRTUAL TABLE memory_chunks_fts USING fts5(
      path UNINDEXED,
      heading UNINDEXED,
      line_start UNINDEXED,
      line_end UNINDEXED,
      body
    )
    """
  end
end

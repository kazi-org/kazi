defmodule Kazi.Repo.Migrations.CreateMemoryChunksFts do
  @moduledoc """
  ADR-0062 (semantic memory): the FTS5 index over the git-native corpus.

  `memory_chunks_fts` is a SQLite FTS5 virtual table — the "SQLite FTS5 in
  the existing read-model" decision 2 calls for, so budgeted recall (decision
  3) ships with ZERO new dependencies (FTS5 is compiled into the SQLite the
  stack already carries via `ecto_sqlite3`/`exqlite`).

  One row per markdown CHUNK (heading/entry granularity,
  `Kazi.Memory.SemanticIndex` does the chunking): `path` + `line_start` +
  `line_end` are the source attribution (`path:line`) every recalled snippet
  carries; `heading` is the chunk's heading line (empty for a file's
  preamble, before its first heading); `body` is the only tokenized/indexed
  column — the rest are `UNINDEXED` (metadata, not full-text search targets).

  A `CREATE VIRTUAL TABLE` needs raw SQL (Ecto.Migration's `create table` has
  no FTS5 vocabulary); the `down` mirrors it with a plain `DROP TABLE`.
  """

  use Ecto.Migration

  def up do
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

  def down do
    execute "DROP TABLE IF EXISTS memory_chunks_fts"
  end
end

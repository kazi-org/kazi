defmodule Kazi.Repo.Migrations.AddWorkspaceRootToMemoryIndexFiles do
  @moduledoc """
  Issue #977: `memory_index_files` was keyed ONLY on a workspace-relative
  `path`, so two workspaces sharing one read-model (`~/.kazi/kazi.db`) clobber
  each other's rows when both have a file at the same relative path (e.g.
  "CLAUDE.md"). Adds `workspace_root` (the canonicalized absolute workspace
  path — see `Kazi.Memory.SemanticIndex.workspace_root/1`) and widens the
  unique constraint from `[:path]` to the composite `[:workspace_root, :path]`,
  so rows are scoped per workspace instead of colliding.

  Existing rows backfill `workspace_root` to `""` (an explicit "unscoped
  legacy row" marker, not a real workspace) — harmless: `SemanticIndex` always
  re-derives `content_hash` from an on-disk read, so a legacy row simply looks
  like a cache miss on the next refresh and is re-keyed under its real
  workspace_root.
  """

  use Ecto.Migration

  def up do
    alter table(:memory_index_files) do
      add :workspace_root, :string, null: false, default: ""
    end

    drop index(:memory_index_files, [:path], name: :memory_index_files_path_index)
    create unique_index(:memory_index_files, [:workspace_root, :path])
  end

  def down do
    drop index(:memory_index_files, [:workspace_root, :path])
    create unique_index(:memory_index_files, [:path])

    alter table(:memory_index_files) do
      remove :workspace_root
    end
  end
end

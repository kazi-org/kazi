defmodule Kazi.Repo.Migrations.CreateOrientationPackCache do
  @moduledoc """
  T4.6 (ADR-0010 §4): the SHA-keyed orientation-pack cache. Each fresh, stateless
  `claude -p` iteration is given a bounded, ranked orientation pack (T4.2) so it
  starts oriented instead of re-exploring the workspace. Building that pack is not
  free (graph survey + file reads), and two iterations at the same git-SHA failing
  the same predicate set produce a byte-identical pack — so we cache it.

  Each row caches one pack under `Kazi.Context.cache_key(workspace, git_sha,
  failing)` — the stable hash of `(workspace, git-SHA, failing-predicate set)`.
  `workspace` and `git_sha` are stored alongside the key for queryability and
  debugging (the key itself is an opaque digest).

  `blast_radius` is the sorted set of impacted files/symbols the cached pack is
  scoped to. ADR-0010 invalidates the cache *incrementally on the changed blast
  radius*: a cache hit at the same key is only reused while its stored blast radius
  still matches the current one; when the changed files/symbols differ, the entry
  is stale and the pack is rebuilt. Storing it makes that comparison a cheap
  column read rather than a full rebuild-and-diff.

  Rebuildable projection like the rest of the read-model (concept §7): authoritative
  for nothing, safe to drop and repopulate on the next miss.
  """

  use Ecto.Migration

  def change do
    create table(:orientation_pack_cache) do
      # The stable cache key: Kazi.Context.cache_key(workspace, git_sha, failing) —
      # a sha256 hex digest of (workspace, git-SHA, failing-predicate set). Unique:
      # one cached pack per key.
      add :cache_key, :string, null: false

      # The workspace + git-SHA the pack was built at, stored for queryability and
      # debugging (the key is an opaque digest of these plus the failing set).
      add :workspace, :string, null: false
      add :git_sha, :string, null: false

      # The serialized orientation pack (Kazi.Context.Pack). SQLite stores :map as
      # JSON text; Pack.to_serializable/1 produces the JSON-safe shape.
      add :pack, :map, null: false, default: %{}

      # The sorted set of impacted files/symbols the pack is scoped to (its blast
      # radius). A hit is reused only while this still matches the current blast
      # radius; a change here invalidates the entry (ADR-0010 §4).
      add :blast_radius, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    # One cached pack per key; a refreshed pack replaces the prior entry.
    create unique_index(:orientation_pack_cache, [:cache_key])
  end
end

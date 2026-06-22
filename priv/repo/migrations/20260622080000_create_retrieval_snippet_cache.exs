defmodule Kazi.Repo.Migrations.CreateRetrievalSnippetCache do
  @moduledoc """
  T4.9c (ADR-0012): the SHA-keyed retrieval-snippet cache. When per-goal retrieval
  is enabled, a `Kazi.Retrieval` backend (the real one being graphify embeddings,
  T4.9b) embeds the target and similarity-searches the failing predicates — an
  external, heavyweight step. Two iterations at the same git-SHA failing the same
  predicate set over an unchanged blast radius would re-embed and re-retrieve an
  identical result, so we cache it, exactly mirroring the T4.6 orientation-pack
  cache (ADR-0012 §4 "may reuse the SHA-keyed cache to avoid re-embedding an
  unchanged target").

  Each row caches one snippet list under `Kazi.Context.cache_key(workspace,
  git_sha, failing)` — the SAME stable hash of `(workspace, git-SHA, failing set)`
  the orientation-pack cache keys on (the key namespace is shared; the table is
  distinct so retrieval and orientation never collide). `workspace`/`git_sha` are
  stored alongside for queryability/debugging (the key itself is an opaque digest).

  `snippets` is the serialized `[Kazi.Retrieval.Snippet]` the backend returned.
  `blast_radius` is the sorted set of impacted files/symbols the snippets were
  scoped to; like T4.6 a hit is reused only while this still matches the current
  blast radius — a change invalidates the entry (the target moved under us).

  Rebuildable projection like the rest of the read-model (concept §7): authoritative
  for nothing, safe to drop and re-retrieve on the next miss.
  """

  use Ecto.Migration

  def change do
    create table(:retrieval_snippet_cache) do
      # The stable cache key: Kazi.Context.cache_key(workspace, git_sha, failing) —
      # a sha256 hex digest of (workspace, git-SHA, failing-predicate set). Unique:
      # one cached snippet list per key (shared key namespace with T4.6).
      add :cache_key, :string, null: false

      # The workspace + git-SHA the snippets were retrieved at, stored for
      # queryability and debugging (the key is an opaque digest of these plus the
      # failing set).
      add :workspace, :string, null: false
      add :git_sha, :string, null: false

      # The serialized retrieved snippets ([Kazi.Retrieval.Snippet]). SQLite stores
      # an :array of :map as JSON text; each snippet is a JSON-safe map.
      add :snippets, {:array, :map}, null: false, default: []

      # The sorted set of impacted files/symbols the snippets were scoped to (the
      # blast radius). A hit is reused only while this still matches the current
      # blast radius; a change here invalidates the entry (ADR-0012, mirroring
      # T4.6's incremental invalidation).
      add :blast_radius, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    # One cached snippet list per key; a refreshed retrieval replaces the prior row.
    create unique_index(:retrieval_snippet_cache, [:cache_key])
  end
end

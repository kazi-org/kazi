defmodule Kazi.ReadModel.RetrievalSnippetCache do
  @moduledoc """
  One row of the SHA-keyed retrieval-snippet cache (T4.9c, ADR-0012): a single
  cached `[Kazi.Retrieval.Snippet]` keyed on `Kazi.Context.cache_key(workspace,
  git_sha, failing)`.

  This is a read-model projection like `Kazi.ReadModel.OrientationPackCache` —
  authoritative for nothing, rebuildable on the next cache miss. It exists only to
  spare an unchanged target a re-embed + re-retrieval when per-goal retrieval is
  enabled (ADR-0012 §4: "may reuse the SHA-keyed cache to avoid re-embedding an
  unchanged target").

  Fields:

    * `cache_key` — the stable hash of `(workspace, git-SHA, failing set)`; unique
      (the same key namespace `Kazi.Context.cache_key/3` produces for T4.6).
    * `workspace` / `git_sha` — the inputs, stored for queryability/debugging (the
      key is an opaque digest of them plus the failing set).
    * `snippets` — the serialized `[Kazi.Retrieval.Snippet]` the backend returned.
    * `blast_radius` — the sorted set of impacted files/symbols the snippets were
      scoped to; a hit is reused only while this still matches the current blast
      radius (incremental invalidation, mirroring T4.6).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "retrieval_snippet_cache" do
    field(:cache_key, :string)
    field(:workspace, :string)
    field(:git_sha, :string)
    field(:snippets, {:array, :map}, default: [])
    field(:blast_radius, {:array, :string}, default: [])

    timestamps(type: :utc_datetime_usec)
  end

  @required [:cache_key, :workspace, :git_sha, :snippets, :blast_radius]

  @doc """
  Builds a changeset for inserting (or replacing) a cached snippet-list row.

  Validates the required fields; the `cache_key` uniqueness is enforced by the DB
  index and surfaced here as a changeset error so a concurrent insert is a clean
  conflict rather than a crash.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, @required)
    |> validate_required([:cache_key, :workspace, :git_sha])
    |> unique_constraint(:cache_key, name: :retrieval_snippet_cache_cache_key_index)
  end
end

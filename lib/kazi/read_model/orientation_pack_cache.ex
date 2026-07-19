defmodule Kazi.ReadModel.OrientationPackCache do
  @moduledoc """
  One row of the SHA-keyed orientation-pack cache (T4.6, ADR-0010 §4): a single
  cached `Kazi.Context.Pack` keyed on `Kazi.Context.cache_key(workspace, git_sha,
  failing)`.

  This is a read-model projection like `Kazi.ReadModel.Iteration` — authoritative
  for nothing, rebuildable on the next cache miss. It exists only to spare each
  fresh, stateless `claude -p` iteration the cost of rebuilding an identical
  orientation pack.

  Fields:

    * `cache_key` — the stable hash of `(workspace, git-SHA, failing set)`; unique.
    * `workspace` / `git_sha` — the inputs, stored for queryability/debugging (the
      key is an opaque digest of them plus the failing set).
    * `pack` — the serialized `Kazi.Context.Pack` (`Pack.to_serializable/1`).
    * `blast_radius` — the sorted set of impacted files/symbols the pack is scoped
      to; a hit is reused only while this still matches the current blast radius
      (incremental invalidation).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "orientation_pack_cache" do
    field(:cache_key, :string)
    field(:workspace, :string)
    field(:git_sha, :string)
    field(:pack, :map, default: %{})
    field(:blast_radius, {:array, :string}, default: [])

    timestamps(type: :utc_datetime_usec)
  end

  @required [:cache_key, :workspace, :git_sha, :pack, :blast_radius]

  @doc """
  Builds a changeset for inserting (or replacing) a cached pack row.

  Validates the required fields; the `cache_key` uniqueness is enforced by the DB
  index and surfaced here as a changeset error so a concurrent insert is a clean
  conflict rather than a crash.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, @required)
    |> validate_required([:cache_key, :workspace, :git_sha])
    |> unique_constraint(:cache_key, name: :orientation_pack_cache_cache_key_index)
  end
end

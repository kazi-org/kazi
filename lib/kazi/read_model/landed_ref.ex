defmodule Kazi.ReadModel.LandedRef do
  @moduledoc """
  A persisted per-group landed ref (T62.6, issue #1241 part 2): the `{branch,
  pr, merge_commit}` a converged partition landed on, keyed by the run handle
  (`run_ref`, the goal id `kazi status` looks up) and the collective's stable
  per-group `partition_id`.

  This is the read-model projection backing `kazi status`'s per-group landing
  detail. It reuses T44.3/T44.10's landed-ref SHAPE (branch/pr/merge_commit) as
  a single storage mechanism for BOTH a single-goal landing (one row, empty
  `partition_id`) and a `--parallel` run (one row per group) — not a
  parallel-only side table. Like every read-model row it is a rebuildable
  projection, authoritative for nothing.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "run_landed_refs" do
    field(:run_ref, :string)
    field(:partition_id, :string, default: "")
    field(:branch, :string)
    field(:pr, :string)
    field(:merge_commit, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:run_ref, :partition_id]
  @optional [:branch, :pr, :merge_commit]

  @doc """
  Builds a changeset for inserting/upserting a landed-ref row.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:run_ref, :partition_id],
      name: :run_landed_refs_run_ref_partition_id_index
    )
  end
end

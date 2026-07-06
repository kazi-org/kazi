defmodule Kazi.ReadModel.Run do
  @moduledoc """
  A row in the fleet run registry (T46.1, ADR-0057): one `kazi apply` process on
  this machine, upserted on start and heartbeated each loop tick.

  This is the read-model schema backing `Kazi.ReadModel.RunRegistry`. Liveness is
  a derived property (heartbeat staleness), not a stored one — a crashed process
  leaves its last heartbeat behind rather than an explicit "dead" row, which is
  exactly what makes a SIGKILLed run distinguishable from one that never existed.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "runs" do
    field(:run_id, :string)
    field(:pid, :string)
    field(:workspace, :string)
    field(:goal_ref, :string)
    field(:harness, :string)
    field(:model, :string)
    field(:status, :string, default: "running")
    field(:started_at, :utc_datetime_usec)
    field(:heartbeat_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:events_sink_path, :string)
    field(:transcript_sink_path, :string)
    # T46.6 (ADR-0057): the run's declared iteration budget ceiling
    # (`goal.budget.max_iterations`), captured once at registration so the
    # attention queue can compute "budget consumed" fleet-wide with no goal
    # reload. `nil` for an unbounded goal or a pre-T46.6 row.
    field(:max_iterations, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:run_id, :pid, :workspace, :goal_ref, :started_at, :heartbeat_at]
  @optional [
    :harness,
    :model,
    :status,
    :finished_at,
    :events_sink_path,
    :transcript_sink_path,
    :max_iterations
  ]

  @doc """
  Builds a changeset for inserting/upserting a run row.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:run_id)
  end
end

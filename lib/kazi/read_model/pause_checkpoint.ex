defmodule Kazi.ReadModel.PauseCheckpoint do
  @moduledoc """
  A row in the pause/resume checkpoint table (T50.3, ADR-0065 decision 3, issue
  #936 full ask): the minimal state a `Kazi.Scheduler.DepScheduler` run paused
  with `--pause-between-waves` persists so `kazi apply --resume <token>` can
  continue it in a LATER, separate process lifecycle. See
  `priv/repo/migrations/20260709120000_create_pause_checkpoints.exs`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "pause_checkpoints" do
    field(:token, :string)
    field(:goal_hash, :string)
    field(:schema_version, :integer, default: 1)
    field(:states_json, :string)
    field(:outcomes_json, :string)
    field(:reported_frontiers_json, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:token, :goal_hash, :states_json, :outcomes_json, :reported_frontiers_json]
  @optional [:schema_version]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(checkpoint, attrs) do
    checkpoint
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:token)
  end
end

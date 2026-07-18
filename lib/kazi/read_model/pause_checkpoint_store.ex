defmodule Kazi.ReadModel.PauseCheckpointStore do
  @moduledoc """
  The sole reader/writer of `Kazi.ReadModel.PauseCheckpoint` rows (T50.3,
  ADR-0065 decision 3, issue #936 full ask), mirroring the pattern
  `Kazi.ReadModel.RunRegistry` sets for `Kazi.ReadModel.Run`.

  A checkpoint is the DURABLE bridge between a paused `Kazi.Scheduler.DepScheduler`
  run and its resume: it survives the pausing process's exit (the read-model,
  not an in-memory continuation), and `Kazi.Scheduler.DepScheduler.run/2`'s
  `:resume_token` option resolves it in a SEPARATE process lifecycle.
  """

  alias Kazi.ReadModel.PauseCheckpoint
  alias Kazi.ReadModel.Writer
  alias Kazi.Repo

  @doc """
  The goal-set content hash a resume recomputes and compares against the
  persisted checkpoint's `goal_hash` (risk R-E50-3: "goal file changed since
  pause; re-run instead"). Derived from each group's id + `needs` edges (the
  DAG shape that determines readiness) plus the goal's own predicates, so an
  edit to either the dependency edges or what must objectively pass is
  detected.
  """
  @spec goal_hash(Kazi.Goal.t()) :: String.t()
  def goal_hash(%Kazi.Goal{} = goal) do
    shape = %{
      groups:
        Enum.map(goal.groups, fn group ->
          %{id: to_string(group.id), needs: Enum.map(group.needs || [], &to_string/1)}
        end),
      predicates: inspect(goal.predicates)
    }

    :crypto.hash(:sha256, :erlang.term_to_binary({goal.id, shape}))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Persists a checkpoint. `token` is the resume handle the caller generates
  (`Kazi.Scheduler.DepScheduler` mints an `Ecto.UUID` per pause). Overwrites any
  existing row for the same token (a re-pause of an already-paused-and-not-yet-
  resumed run replaces its checkpoint).
  """
  @spec put(map()) :: {:ok, PauseCheckpoint.t()} | {:error, Ecto.Changeset.t()}
  def put(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    case Repo.get_by(PauseCheckpoint, token: Map.fetch!(attrs, "token")) do
      nil -> %PauseCheckpoint{}
      existing -> existing
    end
    |> PauseCheckpoint.changeset(attrs)
    |> Writer.insert_or_update()
  end

  @doc "Fetches a checkpoint by its resume token, or `:error` when unknown."
  @spec fetch(String.t()) :: {:ok, PauseCheckpoint.t()} | :error
  def fetch(token) do
    case Repo.get_by(PauseCheckpoint, token: token) do
      nil -> :error
      checkpoint -> {:ok, checkpoint}
    end
  end

  @doc "Deletes a checkpoint (a completed resume no longer needs it)."
  @spec delete(String.t()) :: :ok
  def delete(token) do
    Writer.delete_all(PauseCheckpoint, %{token: token})
    :ok
  end
end

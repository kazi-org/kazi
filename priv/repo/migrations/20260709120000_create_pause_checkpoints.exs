defmodule Kazi.Repo.Migrations.CreatePauseCheckpoints do
  @moduledoc """
  T50.3 (ADR-0065 decision 3, issue #936 full ask): durable state for
  `--pause-between-waves` / `kazi apply --resume`. A `DepScheduler` run that
  pauses at a frontier boundary persists the minimal state needed to continue in
  a LATER, separate process lifecycle — nothing about scheduler state persists
  today, so this is a new projection (see `Kazi.ReadModel.PauseCheckpoint`).
  """

  use Ecto.Migration

  def change do
    create table(:pause_checkpoints) do
      # The resume handle an operator passes to `kazi apply --resume <token>`.
      add :token, :string, null: false

      # The goal-set content hash at pause time (see
      # `Kazi.ReadModel.PauseCheckpoint.goal_hash/1`). A resume recomputes this
      # from the reloaded goal file and REFUSES on mismatch (risk R-E50-3).
      add :goal_hash, :string, null: false

      # The resume-state schema version, so a future format change can be
      # detected rather than silently misread.
      add :schema_version, :integer, null: false, default: 1

      # group_id => terminal planner state ("converged" | "stuck" |
      # "over_budget" | "blocked"), JSON-encoded (SQLite has no native map/array
      # type in the ecto_sqlite3 adapter path this project pins to).
      add :states_json, :string, null: false

      # group_id => RAW reconciler outcome, JSON-encoded.
      add :outcomes_json, :string, null: false

      # The topological frontier indices already reported via
      # `:on_frontier_complete` at pause time, JSON-encoded (list of integers).
      add :reported_frontiers_json, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pause_checkpoints, [:token])
  end
end

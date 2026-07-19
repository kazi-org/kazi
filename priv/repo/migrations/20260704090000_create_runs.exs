defmodule Kazi.Repo.Migrations.CreateRuns do
  @moduledoc """
  The fleet run registry (T46.1, ADR-0057): one row per `kazi apply` process on
  this machine, upserted at start and heartbeated each loop tick, so a fleet-wide
  view (`kazi dashboard`) can tell "converged and exited" apart from "crashed
  mid-iteration" without any IPC — liveness is heartbeat staleness.
  """

  use Ecto.Migration

  def change do
    create table(:runs) do
      # A process-generated identifier, unique per `kazi apply` invocation (NOT
      # the goal_ref — the same goal can be re-run in a fresh process).
      add :run_id, :string, null: false

      add :pid, :string, null: false
      add :workspace, :string, null: false
      add :goal_ref, :string, null: false
      add :harness, :string
      add :model, :string

      # "running" until a terminal verdict lands (:converged / :stuck /
      # :over_budget / :error); null status is treated as still-running by the
      # staleness query.
      add :status, :string, null: false, default: "running"

      add :started_at, :utc_datetime_usec, null: false
      add :heartbeat_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec

      # Per-run JSONL sink paths (T46.2/T46.3); null until those sinks exist.
      add :events_sink_path, :string
      add :transcript_sink_path, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runs, [:run_id])
    create index(:runs, [:goal_ref])
    create index(:runs, [:status, :heartbeat_at])
  end
end

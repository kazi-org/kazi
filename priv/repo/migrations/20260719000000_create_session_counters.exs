defmodule Kazi.Repo.Migrations.CreateSessionCounters do
  @moduledoc """
  T67.3 (ADR-0079 decision 3): the `session_counters` read-model projection — one
  row per harness session UUID, last-write-wins from the opt-in session-stats
  collector's cumulative counter fact. A READ projection (ADR-0011); its only
  writer is the daemon single-writer path (ADR-0068).

  Every token column is nullable with NO default: honest-unknown (ADR-0046) — a
  counter the transcript never exposes (e.g. `reasoning_tokens`) persists NULL,
  never 0. The `(session_uuid, machine)` uniqueness is the upsert conflict target
  the collector's re-post idempotently overwrites (the collector is opt-in PER
  machine, so one session's counters are scoped to the host that produced them).

  Deliberately absent: any projected-completion / ETA column. The velocity
  surface is rate-and-ratio only (ADR-0046); a fabricated date is unrepresentable
  at the storage layer (R-E67-2).
  """

  use Ecto.Migration

  def change do
    create table(:session_counters) do
      # Identity spine (E65): the immutable session UUID is the join key to
      # `runs.harness_session_id`; `session_name` is a DISPLAY alias only, never
      # a join key. `machine` records which opted-in host produced the counters.
      add :session_uuid, :string, null: false
      add :session_name, :string
      add :machine, :string

      # Cumulative token counters (ADR-0046 cached-vs-fresh split so they
      # reconcile with `runs.budget_*` and `kazi economy`); NULL when unexposed.
      add :input_tokens, :integer
      add :cached_input_tokens, :integer
      add :cache_write_tokens, :integer
      add :output_tokens, :integer
      add :reasoning_tokens, :integer

      # Cumulative event counters + bucketed active-time seconds.
      add :message_count, :integer
      add :tool_call_count, :integer
      add :active_time_s, :integer

      # Window bounds for the rate denominators T67.4 computes.
      add :first_observed_at, :utc_datetime_usec
      add :last_observed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:session_counters, [:session_uuid, :machine])
  end
end

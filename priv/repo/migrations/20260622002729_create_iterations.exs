defmodule Kazi.Repo.Migrations.CreateIterations do
  @moduledoc """
  The iteration / evidence log: one row per convergence-loop iteration
  (concept §5, §7). This is the read-model projection of the per-iteration
  events the loop (T0.7) emits, and the source the vector-history (T1.1) and
  regression detector (T1.2) read back.

  Each row captures, for one observation of one goal:
    * which goal and which iteration (`goal_ref`, `iteration_index`),
    * the full predicate vector for that observation, serialized as evidence
      (`predicate_vector` — id => %{status, evidence}; tracking the whole vector
      is what makes regression/oscillation detectable — concept §5),
    * the action the loop decided to take (`action_kind` + `action_params`),
    * the controller's interpretation (`converged`), and
    * `observed_at` (when the predicates were evaluated) plus Ecto timestamps.
  """

  use Ecto.Migration

  def change do
    create table(:iterations) do
      # The goal this iteration belongs to (Kazi.Goal.id — string or atom,
      # stored as text).
      add :goal_ref, :string, null: false

      # Monotonic, per-goal iteration counter (0-based). Unique within a goal.
      add :iteration_index, :integer, null: false

      # The full predicate vector for this observation, serialized as a JSON map
      # of predicate id => %{status, evidence}. SQLite stores :map as JSON text.
      add :predicate_vector, :map, null: false, default: %{}

      # Whether the controller judged the full vector satisfied this iteration
      # (objective termination — T0.8). Denormalized for cheap convergence
      # analytics queries.
      add :converged, :boolean, null: false, default: false

      # The action the loop decided to take after diffing the vector
      # (:dispatch_agent | :integrate | :deploy | ...). Null when no action was
      # taken (e.g. the terminal converged observation).
      add :action_kind, :string
      add :action_params, :map, null: false, default: %{}

      # When the predicates were evaluated (distinct from the row's inserted_at
      # — the projection may lag the event).
      add :observed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # One row per (goal, iteration); the loop never re-records an index.
    create unique_index(:iterations, [:goal_ref, :iteration_index])

    # History reads (T1.1) and convergence analytics scan by goal in iteration
    # order.
    create index(:iterations, [:goal_ref, :inserted_at])
  end
end

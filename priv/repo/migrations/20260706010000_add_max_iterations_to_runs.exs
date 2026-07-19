defmodule Kazi.Repo.Migrations.AddMaxIterationsToRuns do
  @moduledoc """
  T46.6 (ADR-0057, attention queue): the run's declared iteration budget
  ceiling, captured once at registration (`goal.budget.max_iterations`) so a
  fleet-wide projection can compute "budget consumed" without re-loading the
  goal file. `nil` for an unbounded goal or a pre-T46.6 row.
  """

  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :max_iterations, :integer
    end
  end
end

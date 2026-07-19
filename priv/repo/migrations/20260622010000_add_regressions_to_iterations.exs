defmodule Kazi.Repo.Migrations.AddRegressionsToIterations do
  @moduledoc """
  T1.2 regression: persist the green→red regression flags detected each
  iteration so a regression is queryable from the read-model (concept §5: a
  predicate that was green and went red is a regression, flagged against the
  change that caused it).

  Additive column on the existing iteration / evidence log: a JSON-serialized
  list of flags, each `%{predicate_id, green_iteration, red_iteration, status,
  attributed_dispatch}` (see `Kazi.Loop.RegressionDetector`). Empty list when the
  observation produced no regression — the common case.
  """

  use Ecto.Migration

  def change do
    alter table(:iterations) do
      # The regression flags detected at this observation, serialized as a JSON
      # list. SQLite stores {:array, :map} as JSON text; default [] so existing
      # rows and no-regression observations carry an empty list, not null.
      add :regressions, {:array, :map}, null: false, default: []
    end
  end
end

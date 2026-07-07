defmodule Kazi.Repo.Migrations.AddCauseToRuns do
  @moduledoc """
  T48.4 (ADR-0058 decision 4): persist the honest terminal cause detail
  alongside T48.7's `outcome_cause_class` column.

  `outcome_cause_class` (added by T48.7, unpopulated until this task) carries
  the class string (`"budget_exhausted"` / `"error_wedged"` /
  `"quarantine_blocked"`); this migration adds `outcome_cause_detail`, a
  nullable JSON object carrying the implicated predicate ids, their
  last-observed reasons (stringified — a `Kazi.Loop.ErrorPermanence` reason can
  be a bare atom OR a `{tag, detail}` tuple, neither of which round-trips
  through JSON, so `Kazi.Runtime` renders each with `inspect/1` before
  persisting), and the exhausted budget dimension for a `:budget_exhausted`
  cause. Nullable with NO default: a run with no cause class (the common case
  — a clean converge, or a stop that is exactly what it says it is) persists
  NULL, never `%{}` (honest-unknown, ADR-0046 — absence means "no cause
  classified", not "classified as nothing").
  """

  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :outcome_cause_detail, :map
    end
  end
end

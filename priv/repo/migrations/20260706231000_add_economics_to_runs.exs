defmodule Kazi.Repo.Migrations.AddEconomicsToRuns do
  @moduledoc """
  T48.7 (ADR-0058 decision 1): persist run-end economics on the fleet run
  registry, so a run's cost is queryable from the read-model instead of living
  only in the in-process terminal result (`Kazi.Loop.result/0`).

  Additive columns on the existing `runs` table (T46.1). Honest-unknown
  (ADR-0046): `budget_tokens`, `budget_cached_input_tokens`, and
  `budget_cost_usd` are nullable with NO default — a run whose harness never
  reported usage (the T34.1 `usage` envelope stayed empty all run) persists
  NULL, never 0. `dispatch_count` is loop-tracked (not harness-reported), so it
  defaults to 0 — a run that converges without ever dispatching an agent
  legitimately made zero dispatches, which IS known, not unreported.
  `outcome_cause_class` is added now, nullable, and left unpopulated until T48.4
  (the error-permanence classifier) lands. `context_tier` is the active
  ADR-0047 context tier at termination. `predicate_count` /
  `predicate_kind_histogram` are the goal shape (always computable from the
  goal at run start, so populated on every new finish).
  """

  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :budget_tokens, :integer
      add :budget_cached_input_tokens, :integer
      add :budget_cost_usd, :float
      add :dispatch_count, :integer, null: false, default: 0
      add :outcome_cause_class, :string
      add :context_tier, :integer
      add :predicate_count, :integer
      # :map is JSON on SQLite; default to the empty object so a pre-existing
      # row (or a run this migration predates) reads back `%{}`, not nil.
      add :predicate_kind_histogram, :map, default: %{}
    end
  end
end

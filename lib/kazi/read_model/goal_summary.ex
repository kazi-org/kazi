defmodule Kazi.ReadModel.GoalSummary do
  @moduledoc """
  A per-goal summary row for the operator goal board (T3.6b, UC-018, ADR-0011).

  `Kazi.ReadModel.list_goals/0` returns one of these per goal that has at least
  one recorded iteration. It is a *projection shape*, not an Ecto schema: it
  aggregates the iterations log into exactly what the goal board renders —

    * `goal_ref` — the `Kazi.Goal.id` (string form on disk).
    * `status` — the derived lifecycle state: `:converged` when the latest
      iteration converged, else `:in_progress`.
    * `latest_vector` — the goal's most recent `Kazi.PredicateVector`, which the
      board summarises into a pass/total badge.
    * `iteration_count` — how many iterations have been recorded for the goal.
    * `last_observed_at` — when the latest iteration was observed (board ordering).

  Keeping this distinct from `Kazi.ReadModel.Iteration` keeps the board's read
  contract explicit and stable: the LiveView depends on this shape, not on the
  storage schema.
  """

  alias Kazi.PredicateVector

  @type status :: :converged | :in_progress

  @type t :: %__MODULE__{
          goal_ref: String.t(),
          status: status(),
          latest_vector: PredicateVector.t(),
          iteration_count: non_neg_integer(),
          last_observed_at: DateTime.t()
        }

  @enforce_keys [:goal_ref, :status, :latest_vector, :iteration_count, :last_observed_at]
  defstruct [:goal_ref, :status, :latest_vector, :iteration_count, :last_observed_at]

  @doc """
  Summarises the goal's latest predicate vector as a `{passing, total}` pair —
  the board's at-a-glance progress badge (e.g. `2/3`).
  """
  @spec predicate_summary(t()) :: {non_neg_integer(), non_neg_integer()}
  def predicate_summary(%__MODULE__{latest_vector: %PredicateVector{results: results}}) do
    total = map_size(results)

    passing =
      Enum.count(results, fn {_id, result} ->
        Kazi.PredicateResult.passed?(result)
      end)

    {passing, total}
  end
end

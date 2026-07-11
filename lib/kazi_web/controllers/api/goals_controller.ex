defmodule KaziWeb.API.GoalsController do
  @moduledoc """
  Stateless JSON read of the goal board (issue #1077).

  Mirrors the SAME projection `KaziWeb.GoalBoardLive` already reads from —
  `Kazi.ReadModel.list_goals/0` — rather than opening a second data-access path
  (ADR-0011: pure read projection, never mutates a run/goal/lease).
  """
  use KaziWeb, :controller

  alias Kazi.PredicateResult
  alias Kazi.PredicateVector
  alias Kazi.ReadModel

  @doc "Responds with every goal: id, status, predicate vector, iteration count."
  def index(conn, _params) do
    goals = Enum.map(ReadModel.list_goals(), &goal_json/1)

    json(conn, %{goals: goals})
  end

  defp goal_json(goal) do
    %{
      id: goal.goal_ref,
      status: to_string(goal.status),
      iteration_count: goal.iteration_count,
      predicates: predicate_vector_json(goal.latest_vector)
    }
  end

  defp predicate_vector_json(%PredicateVector{results: results}) do
    results
    |> Enum.sort_by(fn {id, _} -> to_string(id) end)
    |> Enum.map(fn {id, %PredicateResult{status: status}} ->
      %{id: to_string(id), verdict: to_string(status)}
    end)
  end

  defp predicate_vector_json(_vector), do: []
end

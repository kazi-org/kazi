defmodule Kazi.ReadModel.Iteration do
  @moduledoc """
  One row of the iteration / evidence log (concept §5, §7): the projection of a
  single convergence-loop iteration for a goal.

  This is the read-model schema backing `Kazi.ReadModel`. It is *not*
  authoritative — it is a rebuildable projection of the `kazi.events` log
  (concept §7). The fields mirror what the loop (T0.7) produces each iteration
  and what the vector-history (T1.1) / regression detector (T1.2) read back:

    * `goal_ref` — the `Kazi.Goal.id` this iteration belongs to.
    * `iteration_index` — 0-based per-goal counter; unique within a goal.
    * `predicate_vector` — the full vector serialized as `%{"<id>" => %{"status"
      => ..., "evidence" => ...}}`. `Kazi.ReadModel` (de)serializes between this
      JSON shape and `Kazi.PredicateVector`.
    * `converged` — whether the controller judged the full vector satisfied
      (objective termination, T0.8).
    * `action_kind` / `action_params` — the action the loop decided to take.
    * `regressions` — the green→red regression flags detected at this observation
      (T1.2), each with its attributed dispatch; empty list when none.
    * `release_ref` — the release ref recorded on a successful deploy this
      iteration (T3.3c, UC-015); `nil` for non-deploy iterations.
    * `context` — the per-iteration context counters (T34.3, ADR-0046 §2):
      `%{"orientation_cache", "retrieval_cache", "orientation_tokens",
      "evidence_tokens", "retrieval_tokens", "tier"}` (string-keyed on disk). The
      `"tier"` is the active context-budget tier the dispatch ran at (T36.3,
      ADR-0047 §3; default 1, `nil` for a no-dispatch iteration). Empty `%{}` for a
      pre-T34.3 / no-dispatch iteration.
    * `tools` — the per-iteration tool counters (T34.3, ADR-0046 §2):
      `%{"tool_calls", "file_reads", "search_calls", "graph_calls"}` (string-keyed
      on disk). Empty `%{}` when the harness exposed no tool-use stream (absent ≠
      zero).
    * `observed_at` — when the predicates were evaluated.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "iterations" do
    field(:goal_ref, :string)
    field(:iteration_index, :integer)
    field(:predicate_vector, :map, default: %{})
    field(:converged, :boolean, default: false)
    field(:action_kind, :string)
    field(:action_params, :map, default: %{})
    # T1.2 regression: the green→red flags detected at this observation, each
    # %{"predicate_id", "green_iteration", "red_iteration", "status",
    # "attributed_dispatch"} (string-keyed on disk). Empty list when none.
    field(:regressions, {:array, :map}, default: [])
    # T3.3c release tagging: the release ref recorded on a successful deploy this
    # iteration (a git tag by default); nil for non-deploy iterations.
    field(:release_ref, :string)
    # T34.3 (ADR-0046 §2): per-iteration context + tool counters (string-keyed
    # JSON maps). `context` carries the orientation/retrieval cache state + section
    # token estimates; `tools` the tool-call breakdown. Default `%{}` (no counters).
    field(:context, :map, default: %{})
    field(:tools, :map, default: %{})
    field(:observed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required [:goal_ref, :iteration_index, :predicate_vector, :observed_at]
  @optional [
    :converged,
    :action_kind,
    :action_params,
    :regressions,
    :release_ref,
    :context,
    :tools
  ]

  @doc """
  Builds a changeset for inserting an iteration row.

  Validates the required projection fields and that `iteration_index` is
  non-negative; the `(goal_ref, iteration_index)` uniqueness is enforced by the
  DB index (surfaced here as a changeset error).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(iteration, attrs) do
    iteration
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:iteration_index, greater_than_or_equal_to: 0)
    |> unique_constraint(:iteration_index, name: :iterations_goal_ref_iteration_index_index)
  end
end

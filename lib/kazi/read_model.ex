defmodule Kazi.ReadModel do
  @moduledoc """
  The read side of the iteration / evidence log (concept §5, §7).

  `Kazi.ReadModel` is the small API the loop (T0.7) uses to *record* each
  iteration into the local SQLite read-model, and that history (T1.1) and
  convergence analytics use to *read* it back. It owns the translation between
  kazi's in-memory domain shapes (`Kazi.PredicateVector`, `Kazi.Action`) and the
  JSON columns of `Kazi.ReadModel.Iteration`:

    * a `Kazi.PredicateVector` round-trips through `predicate_vector` as
      `%{"<id>" => %{"status" => "<status>", "evidence" => <evidence>}}`;
    * a `Kazi.Action` is flattened into `action_kind` + `action_params`.

  The store is never authoritative — it is a rebuildable projection of the
  `kazi.events` log (concept §7). Recording is therefore best understood as
  *projecting an already-true event*, not as deciding anything.
  """

  import Ecto.Query, only: [from: 2]

  alias Kazi.{Action, PredicateResult, PredicateVector, Repo}
  alias Kazi.ReadModel.Iteration

  @typedoc """
  Attributes for `record_iteration/1`. `:goal_ref` and `:iteration_index` are
  required; `:predicate_vector` accepts a `Kazi.PredicateVector` (or a plain map
  of `id => PredicateResult`); `:action` accepts a `Kazi.Action` (or `nil`).
  """
  @type record_attrs :: %{
          required(:goal_ref) => Kazi.Goal.id(),
          required(:iteration_index) => non_neg_integer(),
          optional(:predicate_vector) => PredicateVector.t() | map(),
          optional(:action) => Action.t() | nil,
          optional(:converged) => boolean(),
          optional(:observed_at) => DateTime.t()
        }

  @doc """
  Records (projects) one convergence-loop iteration into the read-model.

  Serializes the predicate vector and action into the row's JSON columns and
  inserts it. Returns `{:ok, iteration}` or `{:error, changeset}` (e.g. a
  duplicate `(goal_ref, iteration_index)`).

  `:converged` defaults to whether the supplied vector is satisfied
  (`PredicateVector.satisfied?/1`); pass it explicitly to override. `:observed_at`
  defaults to now.
  """
  @spec record_iteration(record_attrs()) ::
          {:ok, Iteration.t()} | {:error, Ecto.Changeset.t()}
  def record_iteration(attrs) do
    vector = normalize_vector(Map.get(attrs, :predicate_vector, PredicateVector.new()))
    action = Map.get(attrs, :action)
    observed_at = Map.get(attrs, :observed_at, DateTime.utc_now())
    converged = Map.get_lazy(attrs, :converged, fn -> PredicateVector.satisfied?(vector) end)

    row = %{
      goal_ref: to_string(Map.fetch!(attrs, :goal_ref)),
      iteration_index: Map.fetch!(attrs, :iteration_index),
      predicate_vector: serialize_vector(vector),
      converged: converged,
      action_kind: action && to_string(action.kind),
      action_params: serialize_action_params(action),
      observed_at: observed_at
    }

    %Iteration{}
    |> Iteration.changeset(row)
    |> Repo.insert()
  end

  @doc """
  Lists the recorded iterations for a goal, in ascending `iteration_index`
  order (the history T1.1 reads).
  """
  @spec list_iterations(Kazi.Goal.id()) :: [Iteration.t()]
  def list_iterations(goal_ref) do
    ref = to_string(goal_ref)

    Repo.all(
      from(i in Iteration,
        where: i.goal_ref == ^ref,
        order_by: [asc: i.iteration_index]
      )
    )
  end

  @doc """
  Fetches one iteration by `(goal_ref, iteration_index)`, or `nil`.
  """
  @spec get_iteration(Kazi.Goal.id(), non_neg_integer()) :: Iteration.t() | nil
  def get_iteration(goal_ref, iteration_index) do
    ref = to_string(goal_ref)
    Repo.get_by(Iteration, goal_ref: ref, iteration_index: iteration_index)
  end

  @doc """
  Returns the most recently recorded iteration for a goal (highest
  `iteration_index`), or `nil` if none has been recorded.
  """
  @spec latest_iteration(Kazi.Goal.id()) :: Iteration.t() | nil
  def latest_iteration(goal_ref) do
    ref = to_string(goal_ref)

    Repo.one(
      from(i in Iteration,
        where: i.goal_ref == ^ref,
        order_by: [desc: i.iteration_index],
        limit: 1
      )
    )
  end

  @doc """
  Rehydrates a stored row's `predicate_vector` back into a
  `Kazi.PredicateVector`. The vector is keyed by string ids (their on-disk
  form); callers that need atom ids re-map them against their own predicate set.
  """
  @spec to_predicate_vector(Iteration.t()) :: PredicateVector.t()
  def to_predicate_vector(%Iteration{predicate_vector: serialized}) do
    serialized
    |> Enum.map(fn {id, %{"status" => status} = entry} ->
      {id, PredicateResult.new(deserialize_status(status), Map.get(entry, "evidence", %{}))}
    end)
    |> PredicateVector.new()
  end

  # --- serialization helpers -------------------------------------------------

  defp normalize_vector(%PredicateVector{} = vector), do: vector
  defp normalize_vector(results) when is_map(results), do: PredicateVector.new(results)

  # id => %{"status" => "<status>", "evidence" => <evidence>}. Ids are stored as
  # strings (atoms don't survive a JSON round-trip).
  defp serialize_vector(%PredicateVector{results: results}) do
    Map.new(results, fn {id, %PredicateResult{status: status, evidence: evidence}} ->
      {to_string(id), %{"status" => to_string(status), "evidence" => evidence}}
    end)
  end

  defp serialize_action_params(nil), do: %{}
  defp serialize_action_params(%Action{params: params}), do: params

  defp deserialize_status(status) when is_binary(status) do
    valid = Enum.map(PredicateResult.statuses(), &to_string/1)

    if status in valid do
      String.to_existing_atom(status)
    else
      raise ArgumentError, "unknown predicate status #{inspect(status)} in read-model"
    end
  end
end

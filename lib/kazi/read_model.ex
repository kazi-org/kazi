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
          optional(:regressions) => [map()],
          optional(:release_ref) => String.t() | nil,
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
      # T1.2 regression: serialize the green→red flags for this observation.
      regressions: serialize_regressions(Map.get(attrs, :regressions, [])),
      # T3.3c release tagging: the release ref recorded on a successful deploy.
      release_ref: Map.get(attrs, :release_ref),
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
  Returns the goal's full per-iteration vector history (T1.1) read back from the
  read-model: a list of `{iteration_index, Kazi.PredicateVector.t()}` in
  ascending `iteration_index` (oldest-first).

  This is the DB-side counterpart to `Kazi.Loop.history/1` (which serves the same
  shape from the running loop's in-memory state): the regression (T1.2) and stuck
  (T1.5) detectors read either, depending on whether they analyse a live loop or
  a persisted run. Vectors are keyed by string predicate ids (their on-disk
  form), as rehydrated by `to_predicate_vector/1`.
  """
  @spec iteration_history(Kazi.Goal.id()) :: [{non_neg_integer(), PredicateVector.t()}]
  def iteration_history(goal_ref) do
    goal_ref
    |> list_iterations()
    |> Enum.map(fn %Iteration{iteration_index: index} = iteration ->
      {index, to_predicate_vector(iteration)}
    end)
  end

  @doc """
  Returns the goal's recorded regression flags (T1.2) across all iterations, in
  ascending `iteration_index` order: a list of `{iteration_index, [flag]}` for
  every iteration that flagged at least one regression. Iterations with no
  regression are omitted (empty result means the goal never regressed).

  Each flag is the string-keyed on-disk form of `Kazi.Loop.RegressionDetector`'s
  flag: `%{"predicate_id", "green_iteration", "red_iteration", "status",
  "attributed_dispatch"}`. This is the queryable surface acceptance #2 requires —
  a regression recorded by the loop is readable back from the read-model.
  """
  @spec regressions(Kazi.Goal.id()) :: [{non_neg_integer(), [map()]}]
  def regressions(goal_ref) do
    goal_ref
    |> list_iterations()
    |> Enum.flat_map(fn %Iteration{iteration_index: index, regressions: regressions} ->
      case regressions || [] do
        [] -> []
        flags -> [{index, flags}]
      end
    end)
  end

  @doc """
  Returns the goal's recorded release refs (T3.3c, UC-015) across all
  iterations, in ascending `iteration_index` order: a list of
  `{iteration_index, release_ref}` for every iteration that recorded one.
  Iterations with no release ref are omitted (empty result means the goal never
  deployed an artifact whose release was tagged).

  This is the queryable surface acceptance #2 requires — a release tagged on a
  successful deploy is readable back from the read-model.
  """
  @spec release_refs(Kazi.Goal.id()) :: [{non_neg_integer(), String.t()}]
  def release_refs(goal_ref) do
    goal_ref
    |> list_iterations()
    |> Enum.flat_map(fn %Iteration{iteration_index: index, release_ref: ref} ->
      case ref do
        nil -> []
        "" -> []
        ref -> [{index, ref}]
      end
    end)
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

  # T1.2 regression: serialize the detector's flags into JSON-safe maps. Each
  # flag's :attributed_dispatch is a %Kazi.Action{} (or nil); it is flattened to
  # its kind/params/metadata so the whole flag survives the JSON round-trip, and
  # all keys are stringified (atoms don't survive JSON). Already-serialized
  # (string-keyed) flags pass through unchanged so re-recording is idempotent.
  defp serialize_regressions(flags) when is_list(flags) do
    Enum.map(flags, &serialize_regression/1)
  end

  defp serialize_regression(%{predicate_id: _} = flag) do
    %{
      "predicate_id" => to_string(flag.predicate_id),
      "green_iteration" => flag.green_iteration,
      "red_iteration" => flag.red_iteration,
      "status" => to_string(flag.status),
      "attributed_dispatch" => serialize_dispatch(Map.get(flag, :attributed_dispatch))
    }
  end

  # An already string-keyed flag (e.g. read back and re-recorded): pass through.
  defp serialize_regression(%{} = flag), do: flag

  defp serialize_dispatch(nil), do: nil

  defp serialize_dispatch(%Action{kind: kind, params: params, metadata: metadata}) do
    %{"kind" => to_string(kind), "params" => params, "metadata" => metadata}
  end

  defp deserialize_status(status) when is_binary(status) do
    valid = Enum.map(PredicateResult.statuses(), &to_string/1)

    if status in valid do
      String.to_existing_atom(status)
    else
      raise ArgumentError, "unknown predicate status #{inspect(status)} in read-model"
    end
  end
end

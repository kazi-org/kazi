defmodule Kazi.Attention.Queue do
  @moduledoc """
  The fleet-wide **attention queue** (T46.6, UC-061, ADR-0057): ranks what
  needs the operator across every registered run, from the SAME persisted
  signals the per-goal detectors already compute — `Kazi.Loop.StuckDetector`
  over the read-model's `iteration_history/1`, the read-model's own
  `regressions/1` log, and the run registry's `max_iterations` ceiling
  (T46.6) against the goal's observed iteration count. It adds one further
  signal, flake suspicion, as a pure read of the same history (a predicate
  whose claim-bearing status has flipped more than once has no stable
  requirement change behind it — worth an operator glance even though no
  detector escalates on it).

  Pure projection (ADR-0011 §2): `build/2` takes the run list and reads the
  per-goal history through injectable functions (default
  `Kazi.ReadModel.iteration_history/1` / `Kazi.ReadModel.regressions/1`) so a
  test can seed both with no DB. It never mutates a run or a goal.

  ## Signals and ranking (the exact choice)

  Five signal types, each producing at most one queue entry per run
  (multiple triggering predicates fold into one entry; `detail.predicate_ids`
  carries the full set):

    * `:cause` (severity 5, highest — T48.14, ADR-0058 decision 4, UC-064) —
      a FINISHED run's read-model row carries a `Kazi.Loop.CauseClass`
      terminal cause of `"error_wedged"` or `"quarantine_blocked"`: a
      config error or a flake-pinned predicate an agent cannot fix by
      itself, so it outranks every other signal — including ordinary
      `:stuck` and a genuine `:budget`/`budget_exhausted` stop, neither of
      which needs the boost (an agent-actionable stuck loop, or a budget the
      operator can reasonably choose to raise). A `"budget_exhausted"` cause
      — or no cause at all (a clean converge, or a stop that is exactly what
      it says it is) — raises no `:cause` entry; those runs are byte-identical
      to before this signal existed.
    * `:stuck` (severity 4) — `Kazi.Loop.StuckDetector.stuck?/2` fires on the
      goal's history: N consecutive observations share the same non-empty
      failing set with no score progress.
    * `:budget` (severity 3) — the run's declared `max_iterations` (captured
      at registration, T46.6) is >= 85% consumed by the observed iteration
      count. Absent `max_iterations` (unbounded goal, or a pre-T46.6 row)
      never fires.
    * `:flake_suspicion` (severity 2) — some predicate's claim-bearing status
      (`:pass`/`:fail`/`:error`) has flipped at least twice across the
      history: nondeterministic-looking, worth a glance even if no detector
      has escalated on it.
    * `:regression_recovered` (severity 1, lowest) — the read-model's
      `regressions/1` log recorded a green→red flip for a predicate that is
      back to `:pass` as of the goal's latest observation: the fix landed,
      but the flip itself is worth a human's awareness.

  Entries are ordered by severity (descending), ties broken by recency (the
  triggering iteration index, descending — the most recently observed signal
  first) and then by `goal_ref` (ascending) so the order is fully pinned —
  two entries that tie on both severity and recency never reorder between
  builds. An empty run list yields an empty queue.
  """

  alias Kazi.Loop.StuckDetector
  alias Kazi.PredicateResult
  alias Kazi.PredicateVector
  alias Kazi.ReadModel.Run

  @budget_threshold 0.85

  # T48.14: the cause classes that name a stop an agent cannot fix by
  # itself (a config error, or every remaining failure quarantined as
  # flaky) — the ONLY classes that raise a `:cause` entry. `"budget_exhausted"`
  # is deliberately excluded: it is a genuine budget stop the operator can
  # reasonably resolve by raising the ceiling, so it keeps today's behavior
  # (no new entry; the existing `:budget` signal already covers it).
  # `"capability_unreachable"` (T49.8, ADR-0064 d4) joins the list: a scenario the
  # demonstrator cannot realize needs a human — the capability is broken or the
  # surface unavailable, not something another dispatch or a bigger budget fixes.
  @needs_human_causes ~w(error_wedged quarantine_blocked capability_unreachable)

  @typedoc "The signal type a queue entry was raised for."
  @type signal :: :cause | :stuck | :budget | :flake_suspicion | :regression_recovered

  @typedoc "One ranked attention-queue entry."
  @type entry :: %{
          goal_ref: String.t(),
          run_id: String.t() | nil,
          signal: signal(),
          severity: pos_integer(),
          predicate_id: String.t() | nil,
          detail: map(),
          iteration_index: integer()
        }

  @severity %{cause: 5, stuck: 4, budget: 3, flake_suspicion: 2, regression_recovered: 1}

  @doc """
  Builds the ranked attention queue over `runs` (typically
  `Kazi.ReadModel.RunRegistry.list/0`).

  Options:

    * `:history_fn` — `(goal_ref -> [{iteration_index, PredicateVector.t()}])`,
      defaults to `Kazi.ReadModel.iteration_history/1`.
    * `:regressions_fn` — `(goal_ref -> [{iteration_index, [map()]}])`,
      defaults to `Kazi.ReadModel.regressions/1`.
  """
  @spec build([Run.t()], keyword()) :: [entry()]
  def build(runs, opts \\ []) when is_list(runs) do
    history_fn = Keyword.get(opts, :history_fn, &Kazi.ReadModel.iteration_history/1)
    regressions_fn = Keyword.get(opts, :regressions_fn, &Kazi.ReadModel.regressions/1)

    runs
    |> Enum.flat_map(&entries_for_run(&1, history_fn, regressions_fn))
    |> Enum.sort_by(&sort_key/1)
  end

  defp entries_for_run(%Run{} = run, history_fn, regressions_fn) do
    history = history_fn.(run.goal_ref) |> Enum.sort_by(fn {index, _vector} -> index end)

    cause_entries(run, history) ++
      stuck_entries(run, history) ++
      budget_entries(run, history) ++
      flake_entries(run, history) ++
      regression_recovered_entries(run, history, regressions_fn)
  end

  # ===========================================================================
  # :cause (T48.14) -- the T48.4 honest terminal cause on a FINISHED run's
  # read-model row, boosted above every other signal for the two classes that
  # name a stop needing a HUMAN (a config error `error_wedged`, or a
  # `quarantine_blocked` set with nothing left an agent can act on). No
  # history lookup needed to classify -- `outcome_cause_class` is only ever
  # populated at terminal projection (`Kazi.Runtime`'s `cause_attrs/1`), so a
  # non-nil value already implies the run finished.
  # ===========================================================================

  defp cause_entries(%Run{outcome_cause_class: class} = run, history)
       when class in @needs_human_causes do
    [
      entry(run, :cause, cause_predicate_id(run), last_iteration_index(history), %{
        cause_class: class,
        cause_detail: run.outcome_cause_detail
      })
    ]
  end

  defp cause_entries(_run, _history), do: []

  defp cause_predicate_id(%Run{outcome_cause_detail: %{"ids" => [id | _]}}), do: id
  defp cause_predicate_id(_run), do: nil

  # ===========================================================================
  # :stuck -- the same detector a live loop uses, read over the persisted history
  # ===========================================================================

  defp stuck_entries(run, history) do
    case StuckDetector.stuck?(history, StuckDetector.default_iterations()) do
      {:stuck, failing_set} ->
        ids = failing_set |> MapSet.to_list() |> Enum.sort()

        [
          entry(run, :stuck, List.first(ids), last_iteration_index(history), %{
            predicate_ids: ids
          })
        ]

      :not_stuck ->
        []
    end
  end

  # ===========================================================================
  # :budget -- the run's declared ceiling (T46.6) vs its observed iteration count
  # ===========================================================================

  defp budget_entries(%Run{max_iterations: nil}, _history), do: []

  defp budget_entries(%Run{max_iterations: max_iterations}, _history)
       when not is_integer(max_iterations) or max_iterations <= 0,
       do: []

  defp budget_entries(%Run{max_iterations: max_iterations} = run, history) do
    case last_iteration_index(history) do
      nil ->
        []

      last_index ->
        consumed = last_index + 1
        ratio = consumed / max_iterations

        if ratio >= @budget_threshold do
          [
            entry(run, :budget, nil, last_index, %{
              consumed_iterations: consumed,
              max_iterations: max_iterations,
              ratio: ratio
            })
          ]
        else
          []
        end
    end
  end

  # ===========================================================================
  # :flake_suspicion -- a predicate whose claim-bearing status has flipped more
  # than once across the history, with no requirement change behind it (the same
  # "claim-bearing" reduction Kazi.Loop.RegressionDetector uses, generalized to
  # any flip rather than just green->red).
  # ===========================================================================

  defp flake_entries(run, history) do
    suspects =
      history
      |> predicate_ids()
      |> Enum.filter(&flaky?(&1, history))
      |> Enum.sort()

    case suspects do
      [] ->
        []

      [primary | _] = ids ->
        [
          entry(run, :flake_suspicion, primary, last_iteration_index(history), %{
            predicate_ids: ids
          })
        ]
    end
  end

  defp predicate_ids(history) do
    history
    |> Enum.flat_map(fn {_index, %PredicateVector{results: results}} -> Map.keys(results) end)
    |> Enum.uniq()
  end

  defp flaky?(id, history) do
    history
    |> claim_bearing_statuses(id)
    |> transitions()
    |> Kernel.>=(2)
  end

  defp claim_bearing_statuses(history, id) do
    for {_index, vector} <- history,
        %PredicateResult{status: status} <- [PredicateVector.get(vector, id)],
        status in [:pass, :fail, :error] do
      status
    end
  end

  defp transitions(statuses) do
    statuses
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] -> a != b end)
  end

  # ===========================================================================
  # :regression_recovered -- a past green->red flip (Kazi.ReadModel.regressions/1)
  # whose predicate is back to :pass as of the latest observation.
  # ===========================================================================

  defp regression_recovered_entries(run, history, regressions_fn) do
    last_vector = last_vector(history)

    recovered =
      run.goal_ref
      |> regressions_fn.()
      |> Enum.flat_map(fn {_index, flags} -> flags end)
      |> Enum.filter(&recovered?(&1, last_vector))
      |> Enum.sort_by(& &1["red_iteration"], :desc)

    case recovered do
      [] ->
        []

      [flag | _] ->
        [
          entry(
            run,
            :regression_recovered,
            flag["predicate_id"],
            last_iteration_index(history),
            %{
              red_iteration: flag["red_iteration"],
              green_iteration: flag["green_iteration"]
            }
          )
        ]
    end
  end

  defp recovered?(flag, last_vector) do
    case PredicateVector.get(last_vector, flag["predicate_id"]) do
      %PredicateResult{status: :pass} -> true
      _ -> false
    end
  end

  # ===========================================================================
  # Shared helpers
  # ===========================================================================

  defp entry(%Run{} = run, signal, predicate_id, iteration_index, detail) do
    %{
      goal_ref: run.goal_ref,
      run_id: run.run_id,
      signal: signal,
      severity: Map.fetch!(@severity, signal),
      predicate_id: predicate_id,
      detail: detail,
      iteration_index: iteration_index || -1
    }
  end

  defp last_iteration_index([]), do: nil
  defp last_iteration_index(history), do: history |> List.last() |> elem(0)

  defp last_vector([]), do: PredicateVector.new(%{})
  defp last_vector(history), do: history |> List.last() |> elem(1)

  # Severity descending, then recency (the triggering iteration index)
  # descending, then goal_ref ascending -- a total, pinned order with no
  # unresolved ties.
  defp sort_key(%{severity: severity, iteration_index: iteration_index, goal_ref: goal_ref}) do
    {-severity, -iteration_index, goal_ref}
  end
end

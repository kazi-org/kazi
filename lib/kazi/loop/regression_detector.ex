defmodule Kazi.Loop.RegressionDetector do
  @moduledoc """
  Regression detection for the convergence loop (T1.2, UC-007, concept §5).

  A *regression* is a predicate that was objectively green and went red without
  the requirement changing — "a fix for predicate A breaks predicate B"
  (concept §5). The loop tracks the WHOLE predicate vector across iterations
  precisely so this is detectable: a predicate that was `:pass` in a prior
  observation and is now `:fail`/`:error` is a regression, **not** progress, and
  must be flagged against the change that caused it rather than silently folded
  back into the work-list (concept §5, ADR-0002 rejects a single exit code for
  exactly this reason).

  This module is **pure**: it is a function over the per-iteration vector history
  (T1.1) and the loop's dispatch log → a list of regression flags. It performs no
  provider calls and holds no process state, so it is unit-testable in isolation
  (script a history + dispatch log, assert the flags). The loop (`Kazi.Loop`)
  owns calling it each observation and recording the flags it returns; that split
  keeps the loop change minimal and additive.

  ## What is (and is not) a regression

  Walking each predicate's trajectory across consecutive *observed* states:

    * a `:pass` → non-`:pass` (`:fail`/`:error`) transition between two adjacent
      observations of that predicate is a **regression** (green → red);
    * a predicate that was **never** green (no prior `:pass`) is **not** a
      regression — a first-time failure is ordinary outstanding work, not a
      requirement that broke;
    * a predicate that is **still** green is not flagged;
    * `:unknown` is treated as *neither* green nor a red regression target: it
      carries no convergence claim (`Kazi.PredicateResult`), so a transition into
      `:unknown` (e.g. a flake quarantined by T1.3) is not a regression, and a
      predicate observed only as `:unknown` between greens does not break the
      green run. The comparison is made against the most recent observation in
      which the predicate carried a real claim.

  Only adjacent *claim-bearing* observations are compared, so a predicate that
  oscillates green → red → green → red is flagged at each distinct green → red
  edge.

  ## Attribution to a dispatch

  A regression is flagged "against the change that caused it" (concept §5). The
  loop's only change-making action is `:dispatch_agent` (integrate/deploy do not
  modify code under the predicates). The dispatch that plausibly caused a
  green → red edge is the **most recent dispatch decided between** the green
  observation and the red observation — i.e. the action the loop took *after*
  observing green and *before* re-observing red.

  The detector consumes a `t:dispatch_log/0`: `{iteration_index, action}` entries
  recording, for each `:dispatch_agent`, the iteration index the loop had reached
  when it decided that dispatch (the index of the observation that produced the
  failing work-list). For a regression first observed red at `red_iteration`
  having last been green at `green_iteration`, the attributed dispatch is the
  most recent dispatch entry with `green_iteration <= idx < red_iteration`. If no
  dispatch falls in that window (e.g. the red appeared without an intervening
  dispatch — an environmental flip), attribution is `nil`: the regression is
  still flagged and surfaced, just not pinned to a dispatch.
  """

  alias Kazi.{Action, PredicateResult, PredicateVector}

  @typedoc """
  A single flagged regression. Carries the predicate id, the iteration it was
  last observed green (`green_iteration`), the iteration it was first observed red
  (`red_iteration`), the red `status` (`:fail` or `:error`), and the attributed
  dispatch (the `Kazi.Action` most plausibly responsible, or `nil` if none falls
  in the green → red window).
  """
  @type flag :: %{
          predicate_id: Kazi.Predicate.id(),
          green_iteration: non_neg_integer(),
          red_iteration: non_neg_integer(),
          status: :fail | :error,
          attributed_dispatch: Action.t() | nil
        }

  @typedoc """
  The per-iteration vector history the detector analyses (the T1.1 shape): a list
  of `{iteration_index, PredicateVector.t()}`. Order is not assumed — the
  detector sorts by `iteration_index` before walking each predicate's trajectory.
  """
  @type history :: [{non_neg_integer(), PredicateVector.t()}]

  @typedoc """
  The dispatch log used for attribution: a list of `{iteration_index, action}`
  pairs, where `iteration_index` is the observation index the loop had reached
  when it decided that dispatch, and `action` is the `:dispatch_agent`
  `Kazi.Action`. Only `:dispatch_agent` actions need appear; other kinds are
  ignored.
  """
  @type dispatch_log :: [{non_neg_integer(), Action.t()}]

  @doc """
  Detects all regressions over the given history, attributing each to the
  dispatch that plausibly caused it.

  Returns a list of `t:flag/0`, one per distinct green → red edge across all
  predicates, ordered by `red_iteration` then `predicate_id`. A history with
  fewer than two observations can carry no regression and yields `[]`.

  ## Examples

      iex> alias Kazi.{PredicateVector, PredicateResult}
      iex> green = PredicateVector.new(%{a: PredicateResult.pass()})
      iex> red = PredicateVector.new(%{a: PredicateResult.fail()})
      iex> [flag] = Kazi.Loop.RegressionDetector.detect([{0, green}, {1, red}], [])
      iex> {flag.predicate_id, flag.green_iteration, flag.red_iteration, flag.status}
      {:a, 0, 1, :fail}

      iex> alias Kazi.{PredicateVector, PredicateResult}
      iex> red = PredicateVector.new(%{a: PredicateResult.fail()})
      iex> Kazi.Loop.RegressionDetector.detect([{0, red}, {1, red}], [])
      []
  """
  @spec detect(history(), dispatch_log()) :: [flag()]
  def detect(history, dispatch_log \\ [])

  def detect(history, _dispatch_log) when length(history) < 2, do: []

  def detect(history, dispatch_log) do
    ordered = Enum.sort_by(history, fn {index, _vector} -> index end)
    dispatches = Enum.sort_by(dispatch_log, fn {index, _action} -> index end)

    ordered
    |> predicate_ids()
    |> Enum.flat_map(fn id -> regressions_for(id, ordered, dispatches) end)
    |> Enum.sort_by(fn flag -> {flag.red_iteration, flag.predicate_id} end)
  end

  # The union of all predicate ids ever observed across the history. A predicate
  # absent from some observations is handled by the per-predicate walk (absence
  # and `:unknown` are skipped, not treated as a transition).
  @spec predicate_ids(history()) :: [Kazi.Predicate.id()]
  defp predicate_ids(history) do
    history
    |> Enum.flat_map(fn {_index, %PredicateVector{results: results}} -> Map.keys(results) end)
    |> Enum.uniq()
  end

  # Walk one predicate's claim-bearing observations in iteration order, emitting a
  # flag at each green → red edge. Only observations where the predicate carries a
  # real claim (:pass / :fail / :error — not absent, not :unknown) advance the
  # "last seen" cursor, so an intervening :unknown/absence does not break a green
  # run or manufacture a transition.
  @spec regressions_for(Kazi.Predicate.id(), history(), dispatch_log()) :: [flag()]
  defp regressions_for(id, ordered, dispatches) do
    states = claim_bearing_states(id, ordered)

    for {{prev_idx, :pass}, {curr_idx, curr_status}} <- edges(states),
        curr_status in [:fail, :error] do
      flag(id, prev_idx, curr_idx, curr_status, dispatches)
    end
  end

  # The predicate's claim-bearing observations as `{iteration_index, status}`,
  # in iteration order. Observations where the predicate is absent or :unknown are
  # dropped (no claim → cannot be a regression endpoint).
  @spec claim_bearing_states(Kazi.Predicate.id(), history()) ::
          [{non_neg_integer(), PredicateResult.status()}]
  defp claim_bearing_states(id, ordered) do
    for {index, vector} <- ordered,
        %PredicateResult{status: status} <- [PredicateVector.get(vector, id)],
        status in [:pass, :fail, :error] do
      {index, status}
    end
  end

  # Adjacent pairs of claim-bearing states, each tagged so the green → red test in
  # the caller reads clearly: `{{green_idx, green_status}, {red_idx, red_status}}`.
  @spec edges([{non_neg_integer(), PredicateResult.status()}]) ::
          [
            {{non_neg_integer(), PredicateResult.status()},
             {non_neg_integer(), PredicateResult.status()}}
          ]
  defp edges(states) do
    states
    |> Enum.zip(Enum.drop(states, 1))
  end

  # Build a regression flag, resolving the attributed dispatch from the window
  # [green_iteration, red_iteration).
  @spec flag(
          Kazi.Predicate.id(),
          non_neg_integer(),
          non_neg_integer(),
          :fail | :error,
          dispatch_log()
        ) :: flag()
  defp flag(id, green_idx, red_idx, red_status, dispatches) do
    %{
      predicate_id: id,
      green_iteration: green_idx,
      red_iteration: red_idx,
      status: red_status,
      attributed_dispatch: attribute(green_idx, red_idx, dispatches)
    }
  end

  # The dispatch most plausibly responsible for a green → red edge: the most
  # recent `:dispatch_agent` decided in the window [green_iteration,
  # red_iteration). `nil` if no dispatch falls in that window (the red appeared
  # without an intervening change — not pinnable to a dispatch).
  @spec attribute(non_neg_integer(), non_neg_integer(), dispatch_log()) :: Action.t() | nil
  defp attribute(green_idx, red_idx, dispatches) do
    dispatches
    |> Enum.filter(fn {index, %Action{kind: kind}} ->
      kind == :dispatch_agent and index >= green_idx and index < red_idx
    end)
    |> List.last()
    |> case do
      nil -> nil
      {_index, %Action{} = action} -> action
    end
  end
end

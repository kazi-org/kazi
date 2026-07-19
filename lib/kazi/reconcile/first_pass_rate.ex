defmodule Kazi.Reconcile.FirstPassRate do
  @moduledoc """
  The **predicate first-pass rate** (T68.9, issue #1501): the fraction of a
  goal's authored predicates that were already GREEN on the FIRST observation —
  before the grind loop did any work — versus the ones that started red and
  needed the reconcile loop (predicate/plan rework) to reach `:pass`.

  It is the single best proxy for *just-in-time authoring quality*. A high
  first-pass rate means the `acc:` lines were drafted against fresh, accurate
  context; a low one means the DISPATCH layer (not the grind loop) is the weak
  point — predicates authored against stale context that the loop then has to
  rescue.

  ## What "first pass" means

  The read-model records one `Kazi.PredicateVector` per loop iteration
  (`Kazi.ReadModel.iteration_history/1`, oldest-first). The FIRST vector is the
  initial observation of the authored predicate set. A predicate that is `:pass`
  in that first vector is a **first-pass** predicate (needed no rework); anything
  else (`:fail`/`:error`/`:unknown`) is **reworked** — the loop had to drive it
  green.

  `rate = first_pass / total`, a 0.0–1.0 gradient (`nil` when there is nothing
  to measure — no recorded iterations, or an empty vector). This is a pure,
  deterministic projection over already-persisted iteration data: it reads the
  read-model, never re-runs a provider.

  ## Aggregation

  `aggregate/1` pools per-goal summaries into one fleet-wide figure by SUMMING
  numerators and denominators (a predicate-weighted mean, not a mean-of-means):
  ten predicates on one goal count ten times as much as one predicate on
  another, which is the honest reading of "what fraction of all authored
  predicates were first-pass".
  """

  alias Kazi.PredicateVector

  @typedoc """
  A first-pass summary. `rate` is `first_pass / total` (nil when `total == 0`).
  """
  @type t :: %{
          total: non_neg_integer(),
          first_pass: non_neg_integer(),
          reworked: non_neg_integer(),
          rate: float() | nil
        }

  @doc """
  Summarizes a goal's first-pass rate from its iteration history — the
  `[{iteration_index, PredicateVector.t()}]` list `Kazi.ReadModel.iteration_history/1`
  returns (ascending index). Returns `nil` when there is no history to measure.

  ## Examples

      iex> pass = Kazi.PredicateResult.pass()
      iex> fail = Kazi.PredicateResult.fail()
      iex> first = Kazi.PredicateVector.new(%{a: pass, b: fail})
      iex> last = Kazi.PredicateVector.new(%{a: pass, b: pass})
      iex> Kazi.Reconcile.FirstPassRate.from_history([{0, first}, {1, last}])
      %{total: 2, first_pass: 1, reworked: 1, rate: 0.5}
  """
  @spec from_history([{non_neg_integer(), PredicateVector.t()}]) :: t() | nil
  def from_history([]), do: nil

  def from_history(history) when is_list(history) do
    {_index, first_vector} = Enum.min_by(history, fn {index, _vector} -> index end)
    from_vector(first_vector)
  end

  @doc """
  Summarizes the first-pass rate from a single (first-observation) vector.
  Returns `nil` for an empty vector — there is no authored surface to score.
  """
  @spec from_vector(PredicateVector.t()) :: t() | nil
  def from_vector(%PredicateVector{results: results}) when map_size(results) == 0, do: nil

  def from_vector(%PredicateVector{} = vector) do
    total = PredicateVector.size(vector)
    first_pass = length(PredicateVector.passing(vector))

    summarize(total, first_pass)
  end

  @doc """
  Pools a list of per-goal summaries (each a `t/0`, `nil`s ignored) into one
  fleet-wide summary by summing numerators and denominators. Returns `nil` when
  nothing measurable was supplied.

  ## Examples

      iex> a = %{total: 4, first_pass: 3, reworked: 1, rate: 0.75}
      iex> b = %{total: 1, first_pass: 0, reworked: 1, rate: 0.0}
      iex> Kazi.Reconcile.FirstPassRate.aggregate([a, nil, b])
      %{total: 5, first_pass: 3, reworked: 2, rate: 0.6}
  """
  @spec aggregate([t() | nil]) :: t() | nil
  def aggregate(summaries) when is_list(summaries) do
    measured = Enum.reject(summaries, &is_nil/1)

    case measured do
      [] ->
        nil

      rows ->
        total = Enum.sum(Enum.map(rows, & &1.total))
        first_pass = Enum.sum(Enum.map(rows, & &1.first_pass))
        summarize(total, first_pass)
    end
  end

  defp summarize(0, _first_pass), do: nil

  defp summarize(total, first_pass) do
    %{
      total: total,
      first_pass: first_pass,
      reworked: total - first_pass,
      rate: first_pass / total
    }
  end
end

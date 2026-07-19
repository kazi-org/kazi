defmodule Kazi.PredicateVector do
  @moduledoc """
  The full set of `Kazi.PredicateResult`s for a goal at one observation —
  the predicate *vector* the controller records each iteration (concept §5).

  Tracking the whole vector (not a single pass/fail) is what makes regression and
  oscillation detectable: a predicate that was `:pass` and is now `:fail` between
  two vectors is a regression, not progress (concept §5, ADR-0002 rejects a
  single exit code for exactly this reason). It is also the basis for the
  objective-termination guard (T0.8): the loop may declare `:converged` *only*
  when the whole vector is satisfied — including live predicates, not just code.

  A vector maps each predicate id (`Kazi.Predicate.id/0`) to its result for that
  observation.
  """

  alias Kazi.PredicateResult

  @typedoc "Map of predicate id to its result at one observation."
  @type results :: %{optional(Kazi.Predicate.id()) => PredicateResult.t()}

  @type t :: %__MODULE__{results: results()}

  defstruct results: %{}

  @doc """
  Builds a vector from a map of `id => PredicateResult`, or from a list of
  `{id, PredicateResult}` pairs.

  ## Examples

      iex> r = Kazi.PredicateResult.pass()
      iex> Kazi.PredicateVector.new(%{unit: r}).results[:unit] == r
      true

      iex> Kazi.PredicateVector.new([{:unit, Kazi.PredicateResult.fail()}]).results[:unit].status
      :fail
  """
  @spec new(results() | [{Kazi.Predicate.id(), PredicateResult.t()}]) :: t()
  def new(results) when is_map(results), do: %__MODULE__{results: results}
  def new(results) when is_list(results), do: %__MODULE__{results: Map.new(results)}

  @doc "An empty vector (no predicates observed yet)."
  @spec new() :: t()
  def new, do: %__MODULE__{results: %{}}

  @doc """
  Records (or overwrites) the result for one predicate id, returning the updated
  vector.
  """
  @spec put(t(), Kazi.Predicate.id(), PredicateResult.t()) :: t()
  def put(%__MODULE__{results: results} = vector, id, %PredicateResult{} = result) do
    %{vector | results: Map.put(results, id, result)}
  end

  @doc "Fetches the result for a predicate id, or nil if not present."
  @spec get(t(), Kazi.Predicate.id()) :: PredicateResult.t() | nil
  def get(%__MODULE__{results: results}, id), do: Map.get(results, id)

  @doc """
  Returns true iff the **whole** vector is satisfied — every result is `:pass`.

  This is the objective-termination basis (T0.8): `:converged` is only reachable
  when this returns true over a non-empty vector. An empty vector is **not**
  satisfied: there is nothing to assert convergence over (this also guards
  against a vacuous "all-pass" of zero predicates — cf. the vacuous-goal guard
  T2.3).

  ## Examples

      iex> v = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.pass(), b: Kazi.PredicateResult.pass()})
      iex> Kazi.PredicateVector.satisfied?(v)
      true

      iex> v = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.pass(), b: Kazi.PredicateResult.fail()})
      iex> Kazi.PredicateVector.satisfied?(v)
      false

      iex> Kazi.PredicateVector.satisfied?(Kazi.PredicateVector.new())
      false
  """
  @spec satisfied?(t()) :: boolean()
  def satisfied?(%__MODULE__{results: results}) when map_size(results) == 0, do: false

  def satisfied?(%__MODULE__{results: results}) do
    Enum.all?(results, fn {_id, result} -> PredicateResult.passed?(result) end)
  end

  @doc """
  Returns the ids whose result is `:fail` — the work-list for dispatch
  (concept §5: "the failing predicates ARE the work-list").

  Note this returns only genuine `:fail`s; `:error` and `:unknown` are not
  actionable failing work (see `Kazi.PredicateResult`).

  ## Examples

      iex> v = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.pass(), b: Kazi.PredicateResult.fail()})
      iex> Kazi.PredicateVector.failing(v)
      [:b]
  """
  @spec failing(t()) :: [Kazi.Predicate.id()]
  def failing(%__MODULE__{results: results}) do
    for {id, %PredicateResult{status: :fail}} <- results, do: id
  end

  @doc """
  The number of predicates recorded in the vector — the denominator of the
  green/total rate the portfolio sitrep renders (E64/T64.3).

      iex> v = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.pass(), b: Kazi.PredicateResult.fail()})
      iex> Kazi.PredicateVector.size(v)
      2
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{results: results}), do: map_size(results)

  @doc """
  The ids whose result is green (`:pass`) — the numerator of the green/total rate
  (E64/T64.3). Only genuine passes count; `:fail`/`:error`/`:unknown` do not.

      iex> v = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.pass(), b: Kazi.PredicateResult.fail()})
      iex> Kazi.PredicateVector.passing(v)
      [:a]
  """
  @spec passing(t()) :: [Kazi.Predicate.id()]
  def passing(%__MODULE__{results: results}) do
    for {id, result} <- results, PredicateResult.passed?(result), do: id
  end

  @doc """
  Compares a previous vector to a new one and returns the ids that regressed:
  predicates that were `:pass` in `previous` and are no longer `:pass` in
  `current` (concept §5).

  ## Examples

      iex> prev = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.pass()})
      iex> curr = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.fail()})
      iex> Kazi.PredicateVector.regressions(prev, curr)
      [:a]
  """
  @spec regressions(t(), t()) :: [Kazi.Predicate.id()]
  def regressions(%__MODULE__{results: previous}, %__MODULE__{results: current}) do
    for {id, prev} <- previous,
        PredicateResult.passed?(prev),
        not (current |> Map.get(id) |> passed_or_absent?()) do
      id
    end
  end

  defp passed_or_absent?(nil), do: false
  defp passed_or_absent?(%PredicateResult{} = result), do: PredicateResult.passed?(result)
end

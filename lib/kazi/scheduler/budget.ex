defmodule Kazi.Scheduler.Budget do
  @moduledoc """
  Per-partition **budget split + derived rollup** (T21.7, ADR-0027 step 3; derived
  from ADR-0020/E12's rollup rule, T12.4).

  ADR-0027 runs one reconciler per partition. A goal-set carries ONE hard ceiling
  (`Kazi.Budget`: iterations / wall-clock / tokens, ADR-0002); this module SPLITS
  that ceiling across the partitions so each partition gets its SHARE, and rolls
  the per-partition spend back up into a COLLECTIVE total — the inverse of
  ADR-0020's derived-budget rule, where "a group's budget is the SUM of its
  descendants' budgets" (T12.4). Here the leaves are partitions: the parent total
  is declared and the shares are derived (`share = total / N`), and the collective
  `budget_spent` is the SUM of the partition shares actually spent — exactly the
  "derived rollup" idea applied across partitions instead of predicate groups.

  ## Why split, and why it does not abort siblings

  Splitting makes each partition's spend INDEPENDENTLY BOUNDED: a runaway
  partition exhausts only its OWN share and ESCALATES (`:over_budget`) without
  touching its siblings' budgets. Because the scheduler runs each partition as its
  own supervised task (`Kazi.Scheduler` / `DynamicSupervisor`, `:one_for_one`),
  one partition hitting `:over_budget` is a contained terminal status — the
  collective fold (`Kazi.Scheduler.collective_verdict/1`) surfaces it, but the
  siblings keep running to their own terminals. That is the ADR-0020 promise
  ("per-pillar budgets... without killing the rest") carried into ADR-0027's
  partitions: a partition's budget is a FENCE around its spend, not a kill-switch
  on the run.

  ## The split rule (derived shares)

  `split/2` divides each bounded dimension of the goal budget by N (the partition
  count), giving each partition a floor-share, and hands any remainder to the
  first partitions one unit at a time so the shares SUM BACK to the original total
  (no budget is lost or invented in the split — the rollup is exact). An unbounded
  (`nil`) dimension stays unbounded in every share (splitting "no limit" is still
  "no limit"). A single partition gets the whole budget (the serial degenerate
  case — splitting across one partition is the identity).

  ## The rollup rule (derived total)

  `rollup/1` sums the per-partition spend across each dimension into one collective
  `t:spent/0` — the derived total ADR-0020 describes, computed bottom-up from the
  leaves (partitions). It is order-independent and total: missing dimensions count
  as zero spend. The collective `:over_budget` verdict still comes from
  `Kazi.Scheduler.collective_verdict/1` (any partition `:over_budget` ⇒ collective
  `:over_budget`); `rollup/1` answers the SEPARATE question "how much did the whole
  run spend?", which the verdict does not.

  This module is PURE (no processes, no clock, no I/O): `split/2` and `rollup/1`
  are functions over budget structs and spend maps, so the split-and-rollup rule
  is unit-testable in isolation and cannot couple to the scheduler's runtime.
  """

  alias Kazi.Budget

  @dimensions [:max_iterations, :max_wall_clock_ms, :max_tokens]

  @typedoc """
  A partition's recorded SPEND across the budget dimensions (what it actually
  used), the unit `rollup/1` sums. Each field is a non-negative running total;
  any field may be omitted (counts as zero spent on that dimension). Mirrors
  `Kazi.Loop.Budget.usage/0` keyed by the loop's usage fields.

    * `:iterations` — observe→decide cycles spent;
    * `:elapsed_ms` — wall-clock ms spent;
    * `:tokens`     — token estimate spent.
  """
  @type spent :: %{
          optional(:iterations) => non_neg_integer(),
          optional(:elapsed_ms) => non_neg_integer(),
          optional(:tokens) => non_neg_integer()
        }

  @doc """
  Splits a goal `budget` into `n` per-partition shares whose bounded dimensions
  SUM BACK to the original (a derived, lossless split).

  Each bounded dimension is divided by `n` (floor), with the remainder distributed
  one unit at a time to the first partitions, so `Enum.sum` of a dimension across
  the returned shares equals the original limit exactly. An unbounded (`nil`)
  dimension is `nil` in every share. With `n == 1` the single share IS the budget
  (the serial degenerate case).

  Returns a list of `n` `t:Kazi.Budget.t/0` shares, in partition order (the first
  shares carry any remainder). `n` must be a positive integer.

  ## Examples

      iex> [a, b] = Kazi.Scheduler.Budget.split(%Kazi.Budget{max_iterations: 10}, 2)
      iex> {a.max_iterations, b.max_iterations}
      {5, 5}

      iex> [a, b, c] = Kazi.Scheduler.Budget.split(%Kazi.Budget{max_tokens: 100}, 3)
      iex> {a.max_tokens, b.max_tokens, c.max_tokens}
      {34, 33, 33}

      iex> [only] = Kazi.Scheduler.Budget.split(%Kazi.Budget{max_iterations: 7}, 1)
      iex> only.max_iterations
      7

      iex> [a, b] = Kazi.Scheduler.Budget.split(%Kazi.Budget{max_iterations: nil}, 2)
      iex> {a.max_iterations, b.max_iterations}
      {nil, nil}
  """
  @spec split(Budget.t(), pos_integer()) :: [Budget.t()]
  def split(%Budget{} = budget, n) when is_integer(n) and n > 0 do
    shares_by_dim =
      Map.new(@dimensions, fn dim ->
        {dim, split_dimension(Map.fetch!(budget, dim), n)}
      end)

    for i <- 0..(n - 1) do
      %Budget{
        max_iterations: Enum.at(shares_by_dim.max_iterations, i),
        max_wall_clock_ms: Enum.at(shares_by_dim.max_wall_clock_ms, i),
        max_tokens: Enum.at(shares_by_dim.max_tokens, i),
        # The cached-read weight is a cost-accounting policy, not a ceiling to
        # divide (T34.4): every share keeps the parent's weight verbatim.
        cached_read_weight: budget.cached_read_weight
      }
    end
  end

  # Split one dimension's limit into n shares that sum to the limit. nil
  # (unbounded) stays nil in every share. A bounded limit is floored per share
  # with the remainder spread one unit at a time across the first shares, so the
  # shares sum back to the limit exactly (lossless).
  @spec split_dimension(pos_integer() | nil, pos_integer()) :: [pos_integer() | nil]
  defp split_dimension(nil, n), do: List.duplicate(nil, n)

  defp split_dimension(limit, n) when is_integer(limit) do
    base = div(limit, n)
    remainder = rem(limit, n)

    for i <- 0..(n - 1) do
      base + if(i < remainder, do: 1, else: 0)
    end
  end

  @doc """
  Rolls up a list of per-partition `t:spent/0` into the COLLECTIVE spend (the
  derived total): the dimension-wise SUM across all partitions.

  Order-independent and total — a missing dimension counts as zero, and an empty
  list rolls up to all-zero spend. This is the inverse of `split/2`: the goal
  budget split into shares, the shares' actual spend summed back into one total
  (the ADR-0020/T12.4 derived rollup applied across partitions).

  ## Examples

      iex> Kazi.Scheduler.Budget.rollup([%{tokens: 30}, %{tokens: 12, iterations: 2}])
      %{iterations: 2, elapsed_ms: 0, tokens: 42}

      iex> Kazi.Scheduler.Budget.rollup([])
      %{iterations: 0, elapsed_ms: 0, tokens: 0}
  """
  @spec rollup([spent()]) :: %{
          iterations: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          tokens: non_neg_integer()
        }
  def rollup(spents) when is_list(spents) do
    Enum.reduce(
      spents,
      %{iterations: 0, elapsed_ms: 0, tokens: 0},
      fn spent, acc ->
        %{
          iterations: acc.iterations + Map.get(spent, :iterations, 0),
          elapsed_ms: acc.elapsed_ms + Map.get(spent, :elapsed_ms, 0),
          tokens: acc.tokens + Map.get(spent, :tokens, 0)
        }
      end
    )
  end
end

defmodule Kazi.Loop.Budget do
  @moduledoc """
  The pure budget-ceiling guard for the convergence loop (T1.4, UC-009).

  A goal carries a hard ceiling (`Kazi.Budget`, ADR-0002, concept §4): the loop
  must stop — rather than burn money or spin forever — once it crosses any of
  three independent limits:

    * `:max_iterations`    — the loop has run too many observe→decide cycles;
    * `:max_wall_clock_ms` — too much elapsed wall-clock since it started;
    * `:max_tokens`        — too many estimated tokens spent across harness runs.

  This module holds ONLY the decision: given the budget config and the current
  usage, it returns `:ok` or `{:stop, dimension}` naming the exceeded dimension.
  It performs no I/O, reads no clock, and touches no loop state — the loop
  (`Kazi.Loop`) tracks usage and feeds it in, so the rule is unit-testable in
  isolation and cannot silently couple to the state machine.

  A `nil` budget field means that dimension is unbounded and never trips. Limits
  are checked in a fixed order (iterations, wall-clock, tokens) so a usage that
  crosses several at once yields one deterministic reason.
  """

  alias Kazi.Budget

  @typedoc "The budget dimension that forced the stop."
  @type reason :: :max_iterations | :wall_clock | :token_budget

  @typedoc """
  Current usage fed to `check/2`. Each field is the running total the loop tracks:

    * `:iterations`   — observe→decide cycles completed so far;
    * `:elapsed_ms`   — wall-clock elapsed since the loop started, in ms;
    * `:tokens`       — accumulated token estimate across harness invocations.

  Any field may be omitted; it defaults to `0` (nothing spent on that dimension).
  """
  @type usage :: %{
          optional(:iterations) => non_neg_integer(),
          optional(:elapsed_ms) => non_neg_integer(),
          optional(:tokens) => non_neg_integer()
        }

  @doc """
  Decides whether `usage` has crossed any limit in `budget`.

  Returns `:ok` while every bounded dimension is still within budget, or
  `{:stop, reason}` naming the first exceeded dimension (checked in the order
  iterations → wall-clock → tokens). An unbounded (`nil`) dimension never trips.

  A limit trips when usage reaches OR exceeds it (`>=`): a `max_iterations: 10`
  budget permits iterations 0..9 and stops as the loop is about to begin the
  10th — a hard ceiling, not a soft target.

  ## Examples

      iex> Kazi.Loop.Budget.check(%Kazi.Budget{max_iterations: 3}, %{iterations: 2})
      :ok

      iex> Kazi.Loop.Budget.check(%Kazi.Budget{max_iterations: 3}, %{iterations: 3})
      {:stop, :max_iterations}

      iex> Kazi.Loop.Budget.check(%Kazi.Budget{max_tokens: 100}, %{tokens: 150})
      {:stop, :token_budget}

      iex> Kazi.Loop.Budget.check(%Kazi.Budget{}, %{iterations: 9_999})
      :ok
  """
  @spec check(Budget.t(), usage()) :: :ok | {:stop, reason()}
  def check(%Budget{} = budget, usage) do
    cond do
      exceeded?(budget.max_iterations, Map.get(usage, :iterations, 0)) ->
        {:stop, :max_iterations}

      exceeded?(budget.max_wall_clock_ms, Map.get(usage, :elapsed_ms, 0)) ->
        {:stop, :wall_clock}

      exceeded?(budget.max_tokens, Map.get(usage, :tokens, 0)) ->
        {:stop, :token_budget}

      true ->
        :ok
    end
  end

  # A `nil` limit is unbounded (never trips). Otherwise the dimension is exceeded
  # once usage reaches or passes the limit — a hard ceiling.
  @spec exceeded?(pos_integer() | nil, non_neg_integer()) :: boolean()
  defp exceeded?(nil, _used), do: false
  defp exceeded?(limit, used), do: used >= limit

  @doc """
  Discount cached reads in the token total fed to the gate (T34.4, ADR-0046 #4).

  This is the *cost arithmetic* that precedes `check/2`, NOT the gate decision —
  `check/2` is unchanged. Every major provider prices cached-read input far below
  fresh input, so counting cached reads as fresh would falsely push a cache-hit-
  heavy run `over_budget`. Given the run's full rolled-up token total (cached
  reads already counted at full weight, as `budget_spent.tokens` reports) and the
  cached-read count the usage envelope reported, this rebates the discounted
  fraction so cached reads bill at `weight` of a fresh token:

      budgeted = raw_total − cached_input_tokens × (1 − weight)

  `weight` is clamped to `0.0..1.0` (a cached read is never *more* than a fresh
  token and never negative). When `cached_input_tokens` is `0` — no split was
  reported, or there genuinely were no cached reads — the result equals
  `raw_total`, so the gate behaves byte-identically to the pre-T34.4 all-equal
  arithmetic. The result is floored at `0`.

  ## Examples

      iex> Kazi.Loop.Budget.budgeted_tokens(1000, 0, 0.1)
      1000

      iex> Kazi.Loop.Budget.budgeted_tokens(1000, 900, 0.1)
      190

      iex> Kazi.Loop.Budget.budgeted_tokens(1000, 900, 1.0)
      1000
  """
  @spec budgeted_tokens(non_neg_integer(), non_neg_integer(), number()) :: non_neg_integer()
  def budgeted_tokens(raw_total, cached_input_tokens, weight)
      when is_integer(raw_total) and raw_total >= 0 and
             is_integer(cached_input_tokens) and cached_input_tokens >= 0 and
             is_number(weight) do
    rebate = round(cached_input_tokens * (1.0 - clamp_weight(weight)))
    max(raw_total - rebate, 0)
  end

  # Keep the weight a sane fraction of a fresh token: a cached read never costs
  # more than a fresh one (>1) and never less than nothing (<0).
  @spec clamp_weight(number()) :: number()
  defp clamp_weight(weight) when weight < 0.0, do: 0.0
  defp clamp_weight(weight) when weight > 1.0, do: 1.0
  defp clamp_weight(weight), do: weight
end

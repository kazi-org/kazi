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
end

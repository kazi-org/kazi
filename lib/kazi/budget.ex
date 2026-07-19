defmodule Kazi.Budget do
  @moduledoc """
  A goal's hard ceiling: tokens, wall-clock, iterations, and dispatches
  (ADR-0002, concept §4).

  The budget is a *hard stop* enforced by the controller (T1.4) — when any limit
  is reached the loop terminates as `:over_budget` rather than burning money. A
  `nil` field means that dimension is unbounded. This struct is the declared
  state; the pure decision ("is usage over budget, and on which dimension?")
  lives in `Kazi.Loop.Budget` and is enforced by `Kazi.Loop` once per tick.

  `:max_dispatches` (T48.6, ADR-0058) is a ceiling on `:dispatch_agent` actions
  only — unlike `:max_iterations`, a no-op observe tick never counts against it.
  It exists because iteration cost is not uniform: a wedged run can burn dozens
  of cheap observe-only ticks against `max_iterations` while spending nothing on
  agent dispatches, which makes `max_iterations` a poor proxy for "how much did
  this run actually cost." Set `max_dispatches` when you want a ceiling on
  agent-dispatch spend specifically, independent of how many ticks the loop
  takes to notice convergence.

  `:cached_read_weight` is NOT a ceiling — it is the cost-accounting knob the
  token dimension uses (T34.4, ADR-0046 decision #4). Cached-read input tokens
  are priced far below fresh input on every major provider, so budgeting them as
  fresh would falsely flag a cache-hit-heavy run `over_budget`. The weight is the
  fraction of a fresh token each cached read counts as when the loop computes the
  token total fed to the gate; the *gate decision itself* is unchanged. The
  default (`#{0.1}`) is a low flat weight that matches the documented cache-read
  price ratio of the dominant provider — a conservative stand-in when the exact
  per-model ratio is unknown.
  """

  # The default cached-read weight: cached input tokens count as this fraction of
  # a fresh token in the budget's token arithmetic. ~0.1 mirrors the documented
  # cache-read price ratio of the dominant provider and serves as the "low flat
  # weight when the ratio is unknown" the ADR-0046 honest-default calls for.
  @default_cached_read_weight 0.1

  @type t :: %__MODULE__{
          max_iterations: pos_integer() | nil,
          max_wall_clock_ms: pos_integer() | nil,
          max_tokens: pos_integer() | nil,
          max_dispatches: pos_integer() | nil,
          cached_read_weight: float()
        }

  defstruct max_iterations: nil,
            max_wall_clock_ms: nil,
            max_tokens: nil,
            max_dispatches: nil,
            cached_read_weight: @default_cached_read_weight

  @doc "The default cached-read weight applied when none is configured."
  @spec default_cached_read_weight() :: float()
  def default_cached_read_weight, do: @default_cached_read_weight

  @doc """
  Builds a budget from opts (`:max_iterations`, `:max_wall_clock_ms`,
  `:max_tokens`, `:max_dispatches`, `:cached_read_weight`). Omitted ceiling
  dimensions are unbounded (`nil`); an omitted `:cached_read_weight` defaults to
  `default_cached_read_weight/0`.

  ## Examples

      iex> Kazi.Budget.new(max_iterations: 10).max_iterations
      10

      iex> Kazi.Budget.new(max_dispatches: 5).max_dispatches
      5

      iex> Kazi.Budget.new(cached_read_weight: 0.25).cached_read_weight
      0.25
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      max_iterations: Keyword.get(opts, :max_iterations),
      max_wall_clock_ms: Keyword.get(opts, :max_wall_clock_ms),
      max_tokens: Keyword.get(opts, :max_tokens),
      max_dispatches: Keyword.get(opts, :max_dispatches),
      cached_read_weight: Keyword.get(opts, :cached_read_weight, @default_cached_read_weight)
    }
  end
end

defmodule Kazi.Budget do
  @moduledoc """
  A goal's hard ceiling: tokens, wall-clock, and iterations (ADR-0002, concept
  §4).

  The budget is a *hard stop* enforced by the controller (T1.4) — when any limit
  is reached the loop terminates as `:over_budget` rather than burning money. A
  `nil` field means that dimension is unbounded. Slice 0 carries the budget as
  declared state; the enforcing stuck/budget logic lands in Slice 1.
  """

  @type t :: %__MODULE__{
          max_iterations: pos_integer() | nil,
          max_wall_clock_ms: pos_integer() | nil,
          max_tokens: pos_integer() | nil
        }

  defstruct max_iterations: nil,
            max_wall_clock_ms: nil,
            max_tokens: nil

  @doc """
  Builds a budget from opts (`:max_iterations`, `:max_wall_clock_ms`,
  `:max_tokens`). Omitted dimensions are unbounded (`nil`).

  ## Examples

      iex> Kazi.Budget.new(max_iterations: 10).max_iterations
      10
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      max_iterations: Keyword.get(opts, :max_iterations),
      max_wall_clock_ms: Keyword.get(opts, :max_wall_clock_ms),
      max_tokens: Keyword.get(opts, :max_tokens)
    }
  end
end

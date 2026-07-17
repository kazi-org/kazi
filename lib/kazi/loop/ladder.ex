defmodule Kazi.Loop.Ladder do
  @moduledoc """
  The MODEL escalation ladder (T45.7, ADR-0056 decision 5) — the escalation ladder
  as declared goal-file DATA.

  A goal's `[escalation]` block declares a `ladder` of model ids. When the loop
  reaches a `:stuck` OR `:over_budget` terminal verdict on the same failing
  predicate set (the T30.3 signal), it re-dispatches the SAME goal at the NEXT rung
  (the next model in the ladder) instead of terminating — bounded by the ladder's
  length (and `max_rungs`), at which point the terminal verdict stands.

  This is a distinct concept from `Kazi.Context.Escalation` (T36.4), which bumps
  the CONTEXT-pack tier on non-progress; this walks a MODEL ladder.

  kazi-core holds NO selection policy: this struct only carries the declared list
  and a cursor. It never decides which models are good or in what order beyond what
  the goal-file says. When a goal declares no `[escalation]` block (an empty
  `ladder`), `from_escalation/2` returns `nil` and the loop behaves byte-identically
  to its single-model self.

  ## Per-rung windows

  Each rung is one bounded converge (ADR-0035's bound, preserved): the ladder
  carries the BASELINES (iteration/token/dispatch counts and the wall-clock start)
  captured when the current rung began, so the loop can measure the stuck window
  and the budget PER RUNG — a fresh model gets a fresh window/budget, not the
  exhausted tail of the prior rung's.
  """

  alias Kazi.Goal

  @type spend :: %{
          iterations: non_neg_integer(),
          tokens: non_neg_integer(),
          dispatches: non_neg_integer(),
          now_ms: integer()
        }

  @type t :: %__MODULE__{
          models: [String.t()],
          rung: non_neg_integer(),
          max_rungs: pos_integer(),
          failing: MapSet.t() | nil,
          window_base: non_neg_integer(),
          iter_base: non_neg_integer(),
          token_base: non_neg_integer(),
          dispatch_base: non_neg_integer(),
          clock_base_ms: integer()
        }

  defstruct models: [],
            rung: 0,
            max_rungs: 0,
            failing: nil,
            window_base: 0,
            iter_base: 0,
            token_base: 0,
            dispatch_base: 0,
            clock_base_ms: 0

  @doc """
  Builds a ladder from a goal's `[escalation]` config, or `nil` when no ladder is
  declared (an empty `ladder` — the no-escalation default), so the caller stays on
  its single-model path byte-identically.

  `now_ms` seeds the rung-0 wall-clock baseline.
  """
  @spec from_escalation(Goal.escalation() | nil, integer()) :: t() | nil
  def from_escalation(%{ladder: [_ | _] = models} = escalation, now_ms) do
    declared = length(models)

    max_rungs =
      case Map.get(escalation, :max_rungs) do
        n when is_integer(n) and n > 0 -> min(n, declared)
        _ -> declared
      end

    %__MODULE__{models: models, max_rungs: max_rungs, clock_base_ms: now_ms}
  end

  def from_escalation(_escalation, _now_ms), do: nil

  @doc "The model id for the CURRENT rung (rung 0 is the initial dispatch model)."
  @spec current_model(t()) :: String.t()
  def current_model(%__MODULE__{models: models, rung: rung}), do: Enum.at(models, rung)

  @doc """
  Whether a NEXT rung exists — there is another model to escalate to, within both
  the ladder's length and `max_rungs`. `nil` (no ladder) is never escalatable.
  """
  @spec next?(t() | nil) :: boolean()
  def next?(%__MODULE__{rung: rung, max_rungs: max_rungs}), do: rung + 1 < max_rungs
  def next?(nil), do: false

  @doc """
  Advances to the next rung: bumps the cursor and re-baselines every per-rung
  window (stuck-window + budget) to `spend`, recording the `failing` set this rung
  is being escalated against. Caller reads `current_model/1` for the new model id.
  """
  @spec advance(t(), MapSet.t() | nil, spend()) :: t()
  def advance(%__MODULE__{} = ladder, failing, %{
        iterations: iterations,
        tokens: tokens,
        dispatches: dispatches,
        now_ms: now_ms
      }) do
    %__MODULE__{
      ladder
      | rung: ladder.rung + 1,
        failing: failing,
        window_base: iterations,
        iter_base: iterations,
        token_base: tokens,
        dispatch_base: dispatches,
        clock_base_ms: now_ms
    }
  end
end

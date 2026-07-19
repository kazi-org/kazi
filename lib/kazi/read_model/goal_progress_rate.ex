defmodule Kazi.ReadModel.GoalProgressRate do
  @moduledoc """
  The per-goal progress-RATE projection behind the mission-control "how long
  until done" panel (E63/T63.9, IA Q4, UC-061/UC-068, ADR-0011 — projection only,
  NO new write path).

  ADR-0046 (honest-unknown) is the hard rule for this shape: the operator asked
  "how much longer until projects complete", and the answer is deliberately NOT a
  date or a duration. Fabricating an ETA is the same trust failure as the stale
  attention queue (E63 R-E63-2) — an operator learns to distrust a number that is
  made up. So this struct exposes only OBJECTIVE rate/ratio facts the read-model
  already records and lets the human extrapolate:

    * `predicates` — a `{passing, total}` pair over the goal's latest predicate
      vector (the same at-a-glance ratio the goal board shows). This is a RATIO of
      the current objective state, never a projection forward.

    * `flip_velocity` — a `%{flips, transitions, per_iteration}` summary of how
      many predicates went red→green across the goal's recent iteration
      transitions. `flips` counts every predicate that was not-passing in one
      iteration and passing in the next, summed over the last `@window`
      transitions (`transitions` is how many were actually available — one fewer
      than the iterations in the window, `0` for a single-iteration goal).
      `per_iteration` is `flips / transitions` rounded to one decimal, or `nil`
      when there is no transition to measure (honest-unknown, not a fabricated
      `0.0`). This is a VELOCITY (predicates greening per iteration), never a
      remaining-iterations estimate.

    * `budget` — a `%{consumed, cap}` pair of the run's iteration budget:
      `consumed` is the loop-tracked `dispatch_count` (always known), `cap` is the
      declared `max_iterations` ceiling (`nil` for an unbounded goal or a run that
      never captured one — ADR-0057). This is consumption vs cap, never a
      time-remaining figure.

  Every field is a rate, ratio, or raw count. There is no date, no duration, and
  no ETA anywhere in this shape by construction — the panel that renders it asserts
  that negatively (T63.9 acceptance).

  Built by `Kazi.ReadModel.goal_progress_rate/1`.
  """

  @type flip_velocity :: %{
          flips: non_neg_integer(),
          transitions: non_neg_integer(),
          per_iteration: float() | nil
        }

  @type budget :: %{
          consumed: non_neg_integer(),
          cap: pos_integer() | nil
        }

  @type t :: %__MODULE__{
          goal_ref: String.t(),
          predicates: {non_neg_integer(), non_neg_integer()},
          flip_velocity: flip_velocity(),
          budget: budget()
        }

  @enforce_keys [:goal_ref, :predicates, :flip_velocity, :budget]
  defstruct [:goal_ref, :predicates, :flip_velocity, :budget]
end

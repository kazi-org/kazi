defmodule Kazi.Loop.StuckDetector do
  @moduledoc """
  The pure "stuck" detector for the convergence loop (T1.5, UC-009, concept §5).

  A budget ceiling (T1.4) stops the loop once it has spent too much; the stuck
  detector stops it sooner, the moment progress has *demonstrably stalled* — when
  the loop is making no headway at all. Concept §5/§MVP-1: "a stuck detector (N
  iterations, same failing set) that **escalates to a human** rather than burning
  the budget." Escalation means hand the goal off to a person; the loop must NOT
  keep dispatching agents against a problem it is not solving.

  The signal is the per-iteration history (T1.1): the ordered sequence of
  `Kazi.PredicateVector`s the loop recorded, one per observation. The detector
  reduces each vector to its **failing-predicate-id set** and asks: have the last
  `n` consecutive observations carried the *same, non-empty* failing set? If so
  the loop has re-observed the identical work `n` times running and produced no
  change — it is stuck.

  Everything here is **pure** — no provider calls, no process state, no I/O. The
  loop (`Kazi.Loop`) owns the side effect (firing the human-escalation hook and
  the terminal stop); this module only decides, given the history and `n`, whether
  the loop is stuck and on which failing set. That split keeps the policy
  independently testable (script a history, assert the verdict) and the loop
  change minimal and additive.

  ## Detection rule (the exact choice)

  Given the oldest-first history and a window `n`:

    * Fewer than `n` observations recorded → **not stuck** (not enough evidence;
      a loop must run at least `n` times before it can be declared stuck).
    * The most recent `n` observations have the SAME failing-predicate-id set AND
      that set is **non-empty** → **stuck** on that set. "Same set" is set
      equality on the failing ids, so reordering within a vector does not matter,
      and only genuine `:fail`s count (matching `Kazi.PredicateVector.failing/1`:
      `:error`/`:unknown` are not actionable failing work, so they neither create
      nor sustain a stuck verdict).
    * Otherwise (the set changed across the window, or the window is all-green) →
      **not stuck**. A converging or merely *progressing* loop — one whose failing
      set shrinks, grows, or swaps members between iterations — is making headway
      and must be left to run.

  The empty-set guard is deliberate: a goal that is fully passing for `n`
  iterations is converged, not stuck, and a goal with no failing predicates has
  no work to escalate. Only a persistent, *non-empty* failing set is stuck.
  """

  alias Kazi.PredicateVector

  @typedoc "A failing-predicate-id set for one observation."
  @type failing_set :: MapSet.t(Kazi.Predicate.id())

  @typedoc """
  The detector's verdict: `{:stuck, failing_set}` naming the persistent failing
  set the loop is stuck on, or `:not_stuck`.
  """
  @type verdict :: {:stuck, failing_set()} | :not_stuck

  @doc """
  The default stuck window: the number of consecutive observations that must
  carry the identical, non-empty failing set before the loop is declared stuck.

  Three (concept §5's "N iterations, same failing set") is the smallest window
  that distinguishes a stall from a single re-observation — two identical
  observations can be one fix attempt not yet re-run; three running the same is a
  loop spinning. Injectable via `Kazi.Loop`'s `:stuck_iterations` opt.
  """
  @spec default_iterations() :: pos_integer()
  def default_iterations, do: 3

  @doc """
  Decides whether the loop is stuck over `history` with window `n`.

  `history` is the oldest-first per-iteration vector history (T1.1),
  `[{iteration_index, PredicateVector.t()}]` — exactly what `Kazi.Loop.history/1`
  returns. Returns `{:stuck, failing_set}` when the most recent `n` observations
  carry the same non-empty failing-predicate-id set, otherwise `:not_stuck`.

  `n` must be a positive integer; a non-positive window disables detection
  (always `:not_stuck`), so a `Kazi.Loop` configured with `stuck_iterations: 0`
  never escalates.

  ## Examples

      iex> fail = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.fail()})
      iex> h = [{0, fail}, {1, fail}, {2, fail}]
      iex> Kazi.Loop.StuckDetector.stuck?(h, 3)
      {:stuck, MapSet.new([:a])}

      iex> a = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.fail()})
      iex> b = Kazi.PredicateVector.new(%{b: Kazi.PredicateResult.fail()})
      iex> Kazi.Loop.StuckDetector.stuck?([{0, a}, {1, b}, {2, a}], 3)
      :not_stuck

      iex> pass = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.pass()})
      iex> Kazi.Loop.StuckDetector.stuck?([{0, pass}, {1, pass}, {2, pass}], 3)
      :not_stuck

      iex> fail = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.fail()})
      iex> Kazi.Loop.StuckDetector.stuck?([{0, fail}, {1, fail}], 3)
      :not_stuck
  """
  @spec stuck?(Kazi.Loop.history(), integer()) :: verdict()
  def stuck?(_history, n) when not is_integer(n) or n < 1, do: :not_stuck

  def stuck?(history, n) when is_list(history) do
    window =
      history
      |> Enum.map(fn {_index, %PredicateVector{} = vector} ->
        MapSet.new(PredicateVector.failing(vector))
      end)
      |> Enum.take(-n)

    decide_window(window, n)
  end

  # Not enough observations recorded yet to fill the window → not stuck.
  defp decide_window(window, n) when length(window) < n, do: :not_stuck

  # The window is full: stuck iff every failing set is identical AND non-empty.
  defp decide_window([first | rest] = _window, _n) do
    cond do
      MapSet.size(first) == 0 -> :not_stuck
      Enum.all?(rest, &MapSet.equal?(&1, first)) -> {:stuck, first}
      true -> :not_stuck
    end
  end
end

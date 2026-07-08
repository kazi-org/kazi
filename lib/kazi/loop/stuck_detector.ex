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
      that set is **non-empty** AND no failing predicate's graded score improved
      across the window → **stuck** on that set. "Same set" is set equality on the
      failing ids, so reordering within a vector does not matter, and only genuine
      `:fail`s count (matching `Kazi.PredicateVector.failing/1`: `:error`/`:unknown`
      are not actionable failing work, so they neither create nor sustain a stuck
      verdict).
    * Otherwise (the set changed across the window, the window is all-green, or a
      still-failing predicate's score is *moving the improving way* — ADR-0041's
      graded gradient) → **not stuck**. A converging or merely *progressing* loop —
      one whose failing set shrinks, grows, swaps members, OR whose score climbs
      toward its threshold without yet crossing it — is making headway and must be
      left to run.

  The empty-set guard is deliberate: a goal that is fully passing for `n`
  iterations is converged, not stuck, and a goal with no failing predicates has
  no work to escalate. Only a persistent, *non-empty* failing set is stuck.

  ## The graded-score escape (ADR-0041 / T32.2)

  Boolean is a sparse signal: a predicate stuck on the same fail/fail/fail set
  LOOKS identical whether the agent is flailing or steadily shrinking a 200-error
  lint count toward zero. The envelope-v2 score is the dense gradient that tells
  them apart. When the failing set is identical and non-empty, the detector reads
  each failing predicate's `score` across the window (interpreted through its
  `direction`); if ANY has net-improved from the window's first to last
  observation, the loop is *progressing*, not stuck. A boolean predicate carries
  no score, so this escape never fires for it — the boolean verdict is unchanged.
  """

  alias Kazi.{PredicateResult, PredicateVector}
  alias Kazi.Loop.ErrorPermanence
  alias Kazi.Memory.AttemptLedger

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
    # The most recent `n` observations (oldest-first within the window). We keep
    # the full vectors — not just the failing sets — so the graded-score escape
    # (ADR-0041) can read each failing predicate's score across the window.
    window =
      history
      |> Enum.map(fn {_index, %PredicateVector{} = vector} -> vector end)
      |> Enum.take(-n)

    # ADR-0061 decision 4: the failing-set-per-observation fold is read from
    # `Kazi.Memory.AttemptLedger` — the SAME fold the attempt ledger renders into
    # the dispatch prompt — so controller policy (this stuck verdict) and
    # inner-model context (the ledger section) can never disagree about what the
    # recorded history says.
    failing_sets = history |> AttemptLedger.failing_sets() |> Enum.take(-n)

    decide_window(window, failing_sets, n)
  end

  # Not enough observations recorded yet to fill the window → not stuck.
  defp decide_window(window, _failing_sets, n) when length(window) < n, do: :not_stuck

  # The window is full. Stuck iff every failing set is identical AND non-empty AND
  # no failing predicate's graded score improved across the window.
  defp decide_window(window, failing_sets, _n) do
    [first | rest] = failing_sets

    cond do
      MapSet.size(first) == 0 -> :not_stuck
      not Enum.all?(rest, &MapSet.equal?(&1, first)) -> :not_stuck
      progressing?(window, first) -> :not_stuck
      true -> {:stuck, first}
    end
  end

  # ADR-0041 graded-score escape: true when ANY predicate in the persistent
  # failing set net-improved its score from the window's first to last observation
  # (interpreted through `direction`). Boolean predicates carry no score, so this
  # is always false for them — the boolean stuck verdict is unchanged.
  @spec progressing?([PredicateVector.t()], failing_set()) :: boolean()
  defp progressing?(window, failing_set) do
    Enum.any?(failing_set, fn id -> id_improved?(window, id) end)
  end

  # A single predicate's net score movement across the window: collect its scored
  # observations oldest-first and ask whether the last beats the first the
  # improving way. Needs at least two scored observations to have a delta.
  defp id_improved?(window, id) do
    scored =
      window
      |> Enum.map(&PredicateVector.get(&1, id))
      |> Enum.filter(fn
        %PredicateResult{} = result -> PredicateResult.scored?(result)
        _ -> false
      end)

    case scored do
      [first | _] = list when length(list) >= 2 ->
        last = List.last(list)
        direction = last.direction || first.direction
        improved?(direction, first.score, last.score)

      _ ->
        false
    end
  end

  defp improved?(:higher_better, first, last), do: last > first
  defp improved?(:lower_better, first, last), do: last < first
  defp improved?(_no_direction, _first, _last), do: false

  # ===========================================================================
  # Persistent-:error detection (M5, deep-review-001)
  # ===========================================================================

  @doc """
  Decides whether the loop is stuck on a PERSISTENT `:error` over `history` with
  window `n` — the same non-empty set of predicates reporting `:error` (a
  `:no_provider` predicate, a `custom_script` emitting non-JSON under the `json`
  verdict, a checker that times out every run) across the last `n` consecutive
  observations. A persistent `:error` is a terminal, checker-unrunnable
  condition: it never converges (`all_satisfied?` requires `:pass`), never
  dispatches (`PredicateVector.failing/1` matches only `:fail`), and never
  escalates via `stuck?/2` (which also only reduces on `:fail`) — so, left
  unchecked, the loop would re-observe forever with no budget. This mirrors
  `stuck?/2`'s window logic but classifies on `:error` rather than `:fail`, and
  has no score-progress escape (an errored predicate carries no meaningful
  score gradient).

  Returns `{:error_stuck, error_set}` or `:not_error_stuck`.

  ## Examples

      iex> err = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.error(%{})})
      iex> h = [{0, err}, {1, err}, {2, err}]
      iex> Kazi.Loop.StuckDetector.error_stuck?(h, 3)
      {:error_stuck, MapSet.new([:a])}

      iex> pass = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.pass()})
      iex> Kazi.Loop.StuckDetector.error_stuck?([{0, pass}, {1, pass}, {2, pass}], 3)
      :not_error_stuck
  """
  @spec error_stuck?(Kazi.Loop.history(), integer()) ::
          {:error_stuck, failing_set()} | :not_error_stuck
  def error_stuck?(_history, n) when not is_integer(n) or n < 1, do: :not_error_stuck

  def error_stuck?(history, n) when is_list(history) do
    window =
      history
      |> Enum.map(fn {_index, %PredicateVector{} = vector} -> vector end)
      |> Enum.take(-n)

    decide_error_window(window, n)
  end

  defp decide_error_window(window, n) when length(window) < n, do: :not_error_stuck

  defp decide_error_window(window, _n) do
    error_sets = Enum.map(window, fn vector -> MapSet.new(erroring(vector)) end)
    [first | rest] = error_sets

    cond do
      MapSet.size(first) == 0 -> :not_error_stuck
      not Enum.all?(rest, &MapSet.equal?(&1, first)) -> :not_error_stuck
      true -> {:error_stuck, first}
    end
  end

  # The ids whose result is `:error` — the mirror of `PredicateVector.failing/1`
  # for the error-persistence check.
  defp erroring(%PredicateVector{results: results}) do
    for {id, %PredicateResult{status: :error}} <- results, do: id
  end

  # ===========================================================================
  # Persistent LIVE permanent-error detection (T48.3, ADR-0058, UC-064)
  # ===========================================================================

  @doc """
  Decides whether `history` is stuck on a PERSISTENT, PERMANENTLY-classified
  `:error` over the last `n` observations (T48.3, ADR-0058 §Decision "budget
  honesty"). This is `error_stuck?/2`'s taxonomy-aware sibling: `error_stuck?/2`
  fires on ANY persistent error (transient or permanent alike), which is correct
  for CODE predicates (`Kazi.Loop.code_history/1` — a checker that errors every
  run needs a human regardless of why). LIVE predicates are different: a
  transient live error (a probe timing out while a service is still starting) is
  legitimately still pending and must keep polling (`Kazi.Loop.handle_no_work/2`'s
  bounded backoff) — only a PERMANENT reason (a config problem no amount of
  waiting fixes, e.g. `:missing_url`) justifies stopping promptly instead of
  spinning to `:max_iterations`/`:over_budget` (the ADR-0058 wedge).

  `classify_fun` receives each erroring `PredicateResult` and returns
  `:permanent` or `:transient` (pass `Kazi.Loop.ErrorPermanence.classify_result/1`
  in production; a test can inject any function to script both outcomes without
  depending on the real taxonomy). The verdict requires, across EVERY
  observation in the window:

    * the SAME non-empty set of ids reports `:error` (identical to
      `error_stuck?/2`'s persistence rule), AND
    * EVERY id in that set classifies `:permanent` on THAT observation.

  A single transient-classified observation anywhere in the window withholds
  the verdict entirely (`:not_permanent_error_stuck`) — the window exists to
  tolerate a permanent reason's wording flapping between observations (e.g.
  `:missing_url` today, `:invalid_config` tomorrow, both `:permanent`), not to
  fast-track a mixed transient/permanent stretch. A probe that starts transient
  (still warming up) and only later turns permanent must accumulate a FRESH
  all-permanent window before this fires — exactly "no behavior change for a
  probe that is legitimately warming up" (T48.3 acceptance).

  Returns `{:permanent_error_stuck, error_set, reasons}` where `reasons` is
  `%{id => last_observed_reason}` (the window's most recent observation, for a
  human-readable stop message) or `:not_permanent_error_stuck`.

  ## Examples

      iex> permanent = fn _result -> :permanent end
      iex> err = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.error(%{reason: :missing_url})})
      iex> h = [{0, err}, {1, err}, {2, err}]
      iex> Kazi.Loop.StuckDetector.permanent_error_stuck?(h, 3, permanent)
      {:permanent_error_stuck, MapSet.new([:a]), %{a: :missing_url}}

      iex> transient = fn _result -> :transient end
      iex> err = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.error(%{reason: {:timeout_ms, 100}})})
      iex> h = [{0, err}, {1, err}, {2, err}]
      iex> Kazi.Loop.StuckDetector.permanent_error_stuck?(h, 3, transient)
      :not_permanent_error_stuck

      iex> pass = Kazi.PredicateVector.new(%{a: Kazi.PredicateResult.pass()})
      iex> Kazi.Loop.StuckDetector.permanent_error_stuck?([{0, pass}, {1, pass}, {2, pass}], 3, fn _ -> :permanent end)
      :not_permanent_error_stuck
  """
  @spec permanent_error_stuck?(
          Kazi.Loop.history(),
          integer(),
          (PredicateResult.t() -> ErrorPermanence.permanence())
        ) ::
          {:permanent_error_stuck, failing_set(), %{Kazi.Predicate.id() => term()}}
          | :not_permanent_error_stuck
  def permanent_error_stuck?(_history, n, _classify_fun) when not is_integer(n) or n < 1,
    do: :not_permanent_error_stuck

  def permanent_error_stuck?(history, n, classify_fun)
      when is_list(history) and is_function(classify_fun, 1) do
    window =
      history
      |> Enum.map(fn {_index, %PredicateVector{} = vector} -> vector end)
      |> Enum.take(-n)

    decide_permanent_error_window(window, n, classify_fun)
  end

  defp decide_permanent_error_window(window, n, _classify_fun) when length(window) < n,
    do: :not_permanent_error_stuck

  defp decide_permanent_error_window(window, _n, classify_fun) do
    error_sets = Enum.map(window, fn vector -> MapSet.new(erroring(vector)) end)
    [first | rest] = error_sets

    cond do
      MapSet.size(first) == 0 ->
        :not_permanent_error_stuck

      not Enum.all?(rest, &MapSet.equal?(&1, first)) ->
        :not_permanent_error_stuck

      not all_permanent_across_window?(window, first, classify_fun) ->
        :not_permanent_error_stuck

      true ->
        {:permanent_error_stuck, first, latest_reasons(window, first)}
    end
  end

  # True iff every id in `ids` classifies `:permanent` on EVERY vector in
  # `window` — a single transient-classified (or missing/non-error) observation
  # withholds the verdict (see moduledoc "reason flapping" note).
  @spec all_permanent_across_window?([PredicateVector.t()], failing_set(), function()) ::
          boolean()
  defp all_permanent_across_window?(window, ids, classify_fun) do
    Enum.all?(window, fn vector ->
      Enum.all?(ids, fn id ->
        case PredicateVector.get(vector, id) do
          %PredicateResult{status: :error} = result -> classify_fun.(result) == :permanent
          _ -> false
        end
      end)
    end)
  end

  # The persistent set's most recently observed `:reason` per id (the window's
  # LAST vector), for a human-readable stop — `nil` for a provider that emitted a
  # bare `:error` with no reason evidence (mirrors `ErrorPermanence.classify_result/1`'s
  # own "absence of a reason" handling).
  @spec latest_reasons([PredicateVector.t()], failing_set()) :: %{
          Kazi.Predicate.id() => term()
        }
  defp latest_reasons(window, ids) do
    last = List.last(window)

    Map.new(ids, fn id ->
      reason =
        case PredicateVector.get(last, id) do
          %PredicateResult{evidence: evidence} -> Map.get(evidence, :reason)
          _ -> nil
        end

      {id, reason}
    end)
  end
end

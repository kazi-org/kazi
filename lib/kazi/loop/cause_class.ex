defmodule Kazi.Loop.CauseClass do
  @moduledoc """
  The honest terminal-cause classifier (T48.4, UC-064, ADR-0058 decision 4).

  `over_budget` is not the whole story (ADR-0058 §Context): every diagnosable
  live `over_budget` run investigated turned out to be a mislabeled error-wedge
  — a live predicate stuck in `:error` that the operator "fixed" by raising the
  budget, which changes nothing about a config error. This module names the
  REAL cause alongside the outcome, small and closed by design (do not add a
  class without a production mislabel to justify it):

    * `:budget_exhausted` — a genuine `:over_budget` stop: the terminal
      re-observation (`Kazi.Loop.reeval_terminal_vector/1`, #790) still shows
      real work `:fail`ing, or nothing at all blocking (a live predicate
      legitimately still pending). The right operator move really is "raise the
      budget" (or wait longer).
    * `:error_wedged` — either the T48.3 LIVE permanent-error stuck stop
      (`Kazi.Loop.StuckDetector.permanent_error_stuck?/3`), OR an `:over_budget`
      stop whose terminal re-observation shows ZERO `:fail` but at least one
      PERSISTENT `:error` — the residual case T48.3's stuck window did not get
      a chance to catch (a `stuck_iterations` window longer than the budget
      ceiling, or wall-clock/dispatch dimensions that trip before the window
      fills). Raising the budget does nothing; the fix is the named
      predicate's config.
    * `:quarantine_blocked` — the #820 quarantine-only stuck stop
      (`Kazi.Loop.Flake.quarantine_blocks_only?/2`, wired in
      `Kazi.Loop.handle_no_work/2`): the vector is unsatisfied SOLELY because
      every non-passing id is quarantined as flaky. The fix is rehabilitation
      or a human, not budget.
    * `:workspace_missing` — T53.2 (#1022): the loop's target workspace
      vanished between iterations (the dir is gone, or git reports the
      not-a-repository/deleted-cwd exit-128 signature). This is a distinct
      fatal cause from an ordinary failing-set stall: grinding predicate
      iterations against a dead path can never converge, so the loop stops
      immediately instead of burning the budget. `Kazi.Loop.ErrorPermanence`
      terms: permanent — it will not clear on retry, only on a human
      restoring or re-creating the workspace.

  Every other stop — a clean `:converged`, an ordinary T1.5 failing-set stuck,
  or the pre-existing code `error_stuck?` (M5) stuck — carries **no** cause
  class (`nil`): those are not mislabels, they are exactly what they say they
  are.

  Pure: no I/O, no `Kazi.Loop.Data` coupling — the loop extracts the handful of
  fields this needs (`outcome`, `reason`, the terminal `vector`, and the
  `:stuck`-path breadcrumbs `stuck_cause`/`stuck_failing`/`stuck_reasons`) and
  passes them in as a plain map, so this is unit-testable in complete
  isolation (mirrors `Kazi.Loop.ErrorPermanence` / `Kazi.Loop.StuckDetector`).
  """

  alias Kazi.{PredicateResult, PredicateVector}
  alias Kazi.Loop.Budget

  @typedoc "The honest terminal cause — the RIGHT next move, not just the outcome."
  @type class :: :budget_exhausted | :error_wedged | :quarantine_blocked | :workspace_missing

  @typedoc """
  The cause detail: `ids` are the predicate ids implicated (sorted, `[]` when
  no specific id is implicated — a `:budget_exhausted` stop with nothing
  actually blocking); `reasons` is `%{id => last_observed_reason}` for
  `:error_wedged` (nil for the other two classes, which carry no reason
  taxonomy); `exhausted` is the budget dimension (`Kazi.Loop.Budget.reason/0`)
  for `:budget_exhausted` (nil otherwise).
  """
  @type t :: %{
          class: class(),
          ids: [Kazi.Predicate.id()],
          reasons: %{Kazi.Predicate.id() => term()} | nil,
          exhausted: Budget.reason() | nil
        }

  @typedoc """
  The plain-map input this classifier reads — the loop's terminal state,
  reduced to exactly what the classification needs (no `Kazi.Loop.Data`
  coupling):

    * `:outcome` — `:converged` | `:stopped` | `:over_budget` (or any other
      atom for a non-terminal snapshot; every clause below falls through to
      `nil` for anything that isn't one of the three terminal outcomes).
    * `:reason` — the loop's stop reason (`Kazi.Loop.stop_reason/1`'s result):
      a `Kazi.Loop.Budget.reason()` on `:over_budget`, `:stuck` on a stuck
      `:stopped`, or `nil` on a clean converge.
    * `:vector` — the terminal `Kazi.PredicateVector.t()` (already re-observed
      by `reeval_terminal_vector/1` for an `:over_budget` stop, #790).
    * `:stuck_cause` — `nil` | `:error_wedged` | `:quarantine_blocked`, set by
      the loop AT THE STUCK CALL SITE (`Kazi.Loop.terminate_stuck/4`) — the
      call site already knows exactly why it is stopping, so this is an
      explicit tag rather than an inference over ambiguous shared fields.
    * `:stuck_failing` — the stuck stop's failing-id list (already sorted via
      `Kazi.Loop.stuck_failing_list/1`), or `nil`.
    * `:stuck_reasons` — the T48.3 live-permanent-error reason map, or `nil`.
  """
  @type inputs :: %{
          outcome: atom(),
          reason: atom() | nil,
          vector: PredicateVector.t() | nil,
          stuck_cause: :error_wedged | :quarantine_blocked | nil,
          stuck_failing: [Kazi.Predicate.id()] | nil,
          stuck_reasons: %{Kazi.Predicate.id() => term()} | nil
        }

  @doc """
  Classifies the loop's terminal state into a cause, or `nil` when no
  classification applies (a clean converge, or a stop that is exactly what it
  says it is — see the moduledoc).

  ## Examples

      iex> vector = Kazi.PredicateVector.new(%{code: Kazi.PredicateResult.fail()})
      iex> Kazi.Loop.CauseClass.classify(%{
      ...>   outcome: :over_budget, reason: :max_iterations, vector: vector,
      ...>   stuck_cause: nil, stuck_failing: nil, stuck_reasons: nil
      ...> })
      %{class: :budget_exhausted, ids: [:code], reasons: nil, exhausted: :max_iterations}

      iex> vector = Kazi.PredicateVector.new(%{
      ...>   code: Kazi.PredicateResult.pass(),
      ...>   live: Kazi.PredicateResult.error(%{reason: :missing_url})
      ...> })
      iex> Kazi.Loop.CauseClass.classify(%{
      ...>   outcome: :over_budget, reason: :max_iterations, vector: vector,
      ...>   stuck_cause: nil, stuck_failing: nil, stuck_reasons: nil
      ...> })
      %{class: :error_wedged, ids: [:live], reasons: %{live: :missing_url}, exhausted: nil}

      iex> Kazi.Loop.CauseClass.classify(%{
      ...>   outcome: :stopped, reason: :stuck, vector: nil,
      ...>   stuck_cause: :error_wedged, stuck_failing: [:live],
      ...>   stuck_reasons: %{live: :missing_url}
      ...> })
      %{class: :error_wedged, ids: [:live], reasons: %{live: :missing_url}, exhausted: nil}

      iex> Kazi.Loop.CauseClass.classify(%{
      ...>   outcome: :stopped, reason: :stuck, vector: nil,
      ...>   stuck_cause: :quarantine_blocked, stuck_failing: [:flappy],
      ...>   stuck_reasons: nil
      ...> })
      %{class: :quarantine_blocked, ids: [:flappy], reasons: nil, exhausted: nil}

      iex> Kazi.Loop.CauseClass.classify(%{
      ...>   outcome: :stopped, reason: :stuck, vector: nil,
      ...>   stuck_cause: nil, stuck_failing: [:code], stuck_reasons: nil
      ...> })
      nil

      iex> Kazi.Loop.CauseClass.classify(%{
      ...>   outcome: :converged, reason: nil, vector: nil,
      ...>   stuck_cause: nil, stuck_failing: nil, stuck_reasons: nil
      ...> })
      nil
  """
  @spec classify(inputs()) :: t() | nil
  def classify(%{outcome: :over_budget, reason: reason, vector: %PredicateVector{} = vector}) do
    classify_over_budget(reason, vector)
  end

  def classify(%{outcome: :stopped, reason: :stuck, stuck_cause: :error_wedged} = inputs) do
    %{
      class: :error_wedged,
      ids: sorted_ids(inputs.stuck_failing),
      reasons: inputs.stuck_reasons,
      exhausted: nil
    }
  end

  def classify(%{outcome: :stopped, reason: :stuck, stuck_cause: :quarantine_blocked} = inputs) do
    %{
      class: :quarantine_blocked,
      ids: sorted_ids(inputs.stuck_failing),
      reasons: nil,
      exhausted: nil
    }
  end

  def classify(%{outcome: :stopped, reason: :stuck, stuck_cause: :workspace_missing} = inputs) do
    %{
      class: :workspace_missing,
      ids: sorted_ids(inputs.stuck_failing),
      reasons: inputs.stuck_reasons,
      exhausted: nil
    }
  end

  def classify(_inputs), do: nil

  # An `:over_budget` stop's terminal vector: real `:fail`ing work still
  # blocking → genuinely `:budget_exhausted` (the budget dimension named).
  # Otherwise, zero `:fail` — either a persistent `:error` the T48.3 stuck
  # window never got a chance to catch (a wedge, not budget exhaustion), or
  # nothing at all blocking (a live predicate legitimately still pending, or
  # already satisfied) — still honestly `:budget_exhausted`, just with no
  # specific id to blame.
  @spec classify_over_budget(Budget.reason(), PredicateVector.t()) :: t()
  defp classify_over_budget(reason, vector) do
    case PredicateVector.failing(vector) do
      [] ->
        case erroring_with_reasons(vector) do
          {[], _reasons} ->
            %{class: :budget_exhausted, ids: [], reasons: nil, exhausted: reason}

          {ids, reasons} ->
            %{class: :error_wedged, ids: Enum.sort(ids), reasons: reasons, exhausted: nil}
        end

      failing ->
        %{class: :budget_exhausted, ids: Enum.sort(failing), reasons: nil, exhausted: reason}
    end
  end

  # The erroring ids at the terminal vector + each one's last-observed
  # `evidence[:reason]` — mirrors `Kazi.Loop.StuckDetector`'s private
  # `latest_reasons/2` (the same "reason evidence, or nil if the provider gave
  # none" shape), but over a SINGLE vector rather than a window (an
  # `:over_budget` stop has no persistence window to average over — it is a
  # one-shot re-observation, #790).
  @spec erroring_with_reasons(PredicateVector.t()) :: {[Kazi.Predicate.id()], map()}
  defp erroring_with_reasons(%PredicateVector{results: results}) do
    errors = for {id, %PredicateResult{status: :error} = result} <- results, do: {id, result}
    ids = Enum.map(errors, fn {id, _result} -> id end)

    reasons =
      Map.new(errors, fn {id, %PredicateResult{evidence: evidence}} ->
        {id, Map.get(evidence, :reason)}
      end)

    {ids, reasons}
  end

  defp sorted_ids(nil), do: []
  defp sorted_ids(ids), do: Enum.sort(ids)

  @doc """
  Formats a PERSISTED cause class + its read-model detail map into the single
  human-readable line rendered at both call sites that show a finished run's
  cause (T48.14): the starmap drill-in panel's `cause_line/1`
  (`KaziWeb.MissionControlLive`) and the fleet-wide attention queue
  (`Kazi.Attention.Queue`). One formatter, two call sites, so the two surfaces
  can never drift on how a cause reads.

  `class` is the read-model's `outcome_cause_class` string (`Kazi.ReadModel.Run`);
  `detail` is `outcome_cause_detail` — a string-keyed map (`"reasons"` /
  `"exhausted"` / `"ids"`) as `Kazi.Runtime`'s `cause_attrs/1` persists it, or
  `nil`/anything unrecognized, which yields no suffix.

  ## Examples

      iex> Kazi.Loop.CauseClass.format("error_wedged", %{"reasons" => %{"live_route" => "missing_url"}})
      "error_wedged (live_route: missing_url)"

      iex> Kazi.Loop.CauseClass.format("budget_exhausted", %{"exhausted" => "max_iterations"})
      "budget_exhausted (max_iterations)"

      iex> Kazi.Loop.CauseClass.format("quarantine_blocked", %{"ids" => ["flappy"]})
      "quarantine_blocked (flappy)"

      iex> Kazi.Loop.CauseClass.format("budget_exhausted", %{})
      "budget_exhausted"

  """
  @spec format(String.t(), map() | nil) :: String.t()
  def format(class, detail) when is_binary(class) do
    class <> detail_suffix(detail)
  end

  defp detail_suffix(%{"reasons" => reasons})
       when is_map(reasons) and map_size(reasons) > 0 do
    text =
      reasons
      |> Enum.sort_by(fn {id, _reason} -> id end)
      |> Enum.map_join(", ", fn {id, reason} -> "#{id}: #{reason}" end)

    " (#{text})"
  end

  defp detail_suffix(%{"exhausted" => exhausted}) when is_binary(exhausted),
    do: " (#{exhausted})"

  defp detail_suffix(%{"ids" => [_ | _] = ids}), do: " (#{Enum.join(ids, ", ")})"
  defp detail_suffix(_detail), do: ""
end

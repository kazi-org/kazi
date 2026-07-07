defmodule Kazi.PermanentLiveErrorStuckTest do
  @moduledoc """
  Loop-level enforcement of the LIVE permanent-error stuck stop (T48.3,
  ADR-0058, UC-064) — the fix for the wedge described in ADR-0058 §Context: a
  live `:http_probe` predicate missing its required `:url` errors
  `:missing_url` on EVERY observation, but the pre-T48.3 persistent-`:error`
  detector (`Kazi.Loop.StuckDetector.error_stuck?/2`) is fed `code_history/1`,
  which drops live predicates entirely — so the loop fell through to
  `handle_no_work/2`'s bounded-backoff polling forever, spinning to
  `:max_iterations`/`:over_budget` instead of naming the real, immediately
  diagnosable config problem.

  The pure detection rule (`StuckDetector.permanent_error_stuck?/3`) is unit-
  and doc-tested in isolation in `Kazi.Loop.StuckDetectorTest`; here we prove
  the LOOP wires it correctly:

    * a REAL `Kazi.Providers.HttpProbe` predicate with no `:url` configured
      stops the loop `:stuck`, naming the predicate and the `:missing_url`
      reason, well before any budget ceiling would trip.
    * a live predicate erroring with a TRANSIENT-classified reason (a timeout)
      is NOT stopped — it keeps polling, unchanged from pre-T48.3 behavior.
    * the EXISTING code-predicate `error_stuck?` path (M5, deep-review-001) is
      pinned: a code predicate erroring forever still stops `:stuck` with no
      `stuck_reasons` (that field is LIVE-permanent-error-only).

  T48.4 (ADR-0058 decision 4) extends this suite: the live wedge's `result.cause`
  is `:error_wedged` naming the same ids/reasons as `stuck_reasons`, the pinned
  code `error_stuck?` stop carries NO cause (nil, not a mislabel), and a NEW
  test proves the residual `:over_budget` wedge — a `stuck_iterations` window
  longer than the budget ceiling, so the T48.3 stuck stop never gets a chance
  to fire before the ceiling trips — still classifies `:error_wedged` via the
  terminal re-observation (`Kazi.Loop.CauseClass`), not a bare `:budget_exhausted`.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Budget, Goal, Predicate, PredicateResult}

  # ===========================================================================
  # Test doubles (zero-stub: test-only; the loop depends on the behaviours)
  # ===========================================================================

  # The code predicate is never the problem in these tests — always green, so
  # the loop reaches "landed + deployed, only the live predicate unsatisfied"
  # (decide/2 clause 5) quickly instead of dispatching an agent.
  defmodule AlwaysPassProvider do
    @behaviour Kazi.PredicateProvider
    @impl true
    def evaluate(%Predicate{id: id}, _context), do: PredicateResult.pass(%{id: id})
  end

  # A live provider that errors with a TRANSIENT-classified reason (a request
  # timeout) on EVERY observation — a probe that never stops timing out, but
  # for a reason that MAY clear on its own (ErrorPermanence.classify/1 treats
  # `{:timeout_ms, _}` as `:transient`, mirroring the real HttpProbe timeout
  # path). Proves persistent transient live errors are NOT stopped early.
  defmodule AlwaysTimingOutLiveProvider do
    @behaviour Kazi.PredicateProvider
    @impl true
    def evaluate(%Predicate{id: id}, _context),
      do: PredicateResult.error(%{id: id, reason: {:timeout_ms, 100}})
  end

  # A CODE predicate provider that errors on every observation with a reason
  # ErrorPermanence does not recognise at all (defaults :transient — but this
  # path is the PRE-T48.3 `error_stuck?/2` check over `code_history/1`, which
  # has NO permanence taxonomy and fires on ANY persistent error regardless).
  defmodule AlwaysErroringCodeProvider do
    @behaviour Kazi.PredicateProvider
    @impl true
    def evaluate(%Predicate{id: id}, _context),
      do: PredicateResult.error(%{id: id, reason: :checker_unrunnable})
  end

  defmodule NoopHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{output: "ok"}}
  end

  defmodule ImmediateIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule ImmediateDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp start_loop(goal, providers, opts) do
    base = [
      goal: goal,
      providers: providers,
      harness: NoopHarness,
      integrate: ImmediateIntegrate,
      deploy: ImmediateDeploy,
      # Poll fast so the stuck window fills quickly rather than waiting on the
      # prod default re-observe interval.
      reobserve_interval_ms: 1,
      flake_max_retries: 0
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  # ===========================================================================
  # Tests
  # ===========================================================================

  test "a live http predicate missing :url stops :stuck naming the predicate and reason, " <>
         "not :over_budget at max_iterations" do
    goal =
      Goal.new("missing-url-wedge",
        predicates: [
          Predicate.new(:code, :tests),
          # No :url configured — Kazi.Providers.HttpProbe errors :missing_url
          # on EVERY observation (real provider, no I/O for this path).
          Predicate.new(:live, :http_probe, config: %{})
        ],
        # A budget generous enough that a pre-T48.3 loop would spin to
        # :over_budget instead of ever naming the wedge; the fix must stop far
        # short of it.
        budget: Budget.new(max_iterations: 20)
      )

    {:ok, loop} =
      start_loop(goal, %{tests: AlwaysPassProvider, http_probe: Kazi.Providers.HttpProbe},
        stuck_iterations: 3
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    assert result.outcome == :stopped
    assert result.reason == :stuck
    assert result.stuck_reasons == %{live: :missing_url}
    # T48.4 (ADR-0058 decision 4): the honest terminal cause names this
    # exactly what it is — a config error, not a fixable code failure.
    assert result.cause == %{
             class: :error_wedged,
             ids: [:live],
             reasons: %{live: :missing_url},
             exhausted: nil
           }

    # Stopped well before the 20-iteration budget ceiling would have tripped
    # :over_budget — the whole point of the fix (ADR-0058 "budget honesty").
    assert result.iterations < 20

    snap = Kazi.Loop.snapshot(loop)
    assert snap.stuck_failing == [:live]
    assert snap.stuck_reasons == %{live: :missing_url}
    assert snap.cause == result.cause
  end

  test "an over_budget stop whose stuck window never closes still classifies error_wedged, not a bare budget_exhausted" do
    # T48.4 (ADR-0058 decision 4): the residual case T48.3's stuck window does
    # not get a chance to catch — a `stuck_iterations` window (10) LONGER than
    # the iteration budget (2), so the ceiling trips before the persistent-error
    # stuck check ever fires. The terminal re-observation (#790,
    # `reeval_terminal_vector/1`) still sees the SAME missing-:url error, zero
    # :fail — `Kazi.Loop.CauseClass` must still name this a config-error wedge,
    # not let it fall back to an uninformative :budget_exhausted.
    goal =
      Goal.new("missing-url-wedge-budget",
        predicates: [
          Predicate.new(:code, :tests),
          Predicate.new(:live, :http_probe, config: %{})
        ],
        budget: Budget.new(max_iterations: 2)
      )

    {:ok, loop} =
      start_loop(goal, %{tests: AlwaysPassProvider, http_probe: Kazi.Providers.HttpProbe},
        stuck_iterations: 10
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    assert result.outcome == :over_budget
    assert result.reason == :max_iterations
    # No T48.3 stuck-path breadcrumbs on this stop -- it terminated via the
    # BUDGET path, not `terminate_stuck/4`.
    assert result.stuck_reasons == nil

    assert result.cause == %{
             class: :error_wedged,
             ids: [:live],
             reasons: %{live: :missing_url},
             exhausted: nil
           }
  end

  test "a live predicate erroring with a TRANSIENT reason keeps polling (no stuck stop)" do
    goal =
      Goal.new("transient-live-error",
        predicates: [
          Predicate.new(:code, :tests),
          Predicate.new(:live, :http_probe, config: %{url: "http://example.invalid/healthz"})
        ]
      )

    {:ok, loop} =
      start_loop(
        goal,
        %{tests: AlwaysPassProvider, http_probe: AlwaysTimingOutLiveProvider},
        stuck_iterations: 3
      )

    # Let it run well past the stuck window — a transient live error must NOT
    # trip the new permanent-error stop; the loop keeps backing off and
    # polling, same as pre-T48.3.
    assert {:error, :timeout} = Kazi.Loop.await(loop, 200)

    snap = Kazi.Loop.snapshot(loop)
    refute snap.state == :stopped
    assert snap.iterations >= 3
    assert snap.stuck_failing == nil
    assert snap.stuck_reasons == nil
    # Landed + deployed already (code was green from the start) — the loop is
    # legitimately still polling the live predicate, not stalled elsewhere.
    assert snap.deployed?

    :ok = Kazi.Loop.stop(loop)
  end

  test "existing code-predicate error_stuck behavior is pinned unchanged" do
    goal =
      Goal.new("code-error-stuck-pinned",
        predicates: [Predicate.new(:code, :tests)]
      )

    {:ok, loop} =
      start_loop(goal, %{tests: AlwaysErroringCodeProvider}, stuck_iterations: 3)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    assert result.outcome == :stopped
    assert result.reason == :stuck
    # LIVE-permanent-error-only field: the existing code error_stuck? path
    # carries no reason taxonomy, so this stays nil (additive, not a
    # replacement for the pre-T48.3 shape).
    assert result.stuck_reasons == nil
    # T48.4 (ADR-0058 decision 4): this stop is exactly what it says it is —
    # a code checker persistently unrunnable, not one of the three named
    # mislabels — so it carries NO cause class.
    assert result.cause == nil

    snap = Kazi.Loop.snapshot(loop)
    assert snap.stuck_failing == [:code]
    assert snap.stuck_reasons == nil
    assert snap.cause == nil
  end
end

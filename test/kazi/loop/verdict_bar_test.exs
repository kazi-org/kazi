defmodule Kazi.Loop.VerdictBarTest do
  @moduledoc """
  Issue #795 ("truth lives in the controller" leak): a run must never report
  `:converged` while the terminal predicate vector carries an `:unknown`
  verdict — quarantine (T1.3) included. An `:unknown` predicate carries no
  convergence claim either way; it must never be silently dropped from the
  bar just because it is also excluded from the work-list.

  Regression coverage for the fix in `Kazi.Loop.decide/2` / `all_satisfied?/1`
  (loop.ex) and the underlying `Kazi.PredicateVector.satisfied?/1` guarantee it
  now relies on unconditionally.

  #820 note: fixing #795 (never silently converge on a quarantined `:unknown`)
  left the loop with no terminal escape when quarantine was the ONLY blockage —
  it idled at the reobserve interval forever (or to `max_iterations`). The first
  test below originally asserted exactly that idle (`{:error, :timeout}`); #820's
  honest-termination path (`Kazi.Loop.Flake.quarantine_blocks_only?/2`, see
  `Kazi.Loop.QuarantineExitTest`) now stops it `:stuck` instead — updated here to
  match, while still proving the core #795 invariant: never `:converged`, never
  re-dispatched as work.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateProvider, PredicateResult, PredicateVector}

  describe "Kazi.PredicateVector.satisfied?/1: an :unknown result never counts toward the bar" do
    test "a lone :unknown result is not satisfied" do
      v = PredicateVector.new(%{p: PredicateResult.unknown()})
      refute PredicateVector.satisfied?(v)
    end

    test "an :unknown result alongside all-:pass results still is not satisfied" do
      v =
        PredicateVector.new(%{
          a: PredicateResult.pass(),
          b: PredicateResult.pass(),
          c: PredicateResult.unknown()
        })

      refute PredicateVector.satisfied?(v)
    end
  end

  # ===========================================================================
  # Full-loop reproduction of issue #795: a 2-predicate goal where one
  # predicate genuinely flakes (fail/pass alternating within an observation),
  # gets quarantined (recorded :unknown, T1.3), while the other predicate is
  # solidly green. Ground truth: the goal is NOT objectively converged — one
  # predicate's true state is unknown — so the loop must never report
  # `:converged`, and must not re-dispatch the quarantined predicate as work
  # either (it is not `:fail`).
  # ===========================================================================

  defmodule FlakyProvider do
    @moduledoc false
    @behaviour PredicateProvider
    use Agent

    def start_link(_), do: Agent.start_link(fn -> 0 end)

    @impl true
    def evaluate(%Predicate{id: :flaky}, context) do
      pid = context.goal.metadata.flaky_pid
      n = Agent.get_and_update(pid, fn n -> {n, n + 1} end)
      status = if rem(n, 2) == 0, do: :fail, else: :pass
      PredicateResult.new(status, %{eval: n})
    end
  end

  defmodule SolidProvider do
    @moduledoc false
    @behaviour PredicateProvider

    @impl true
    def evaluate(%Predicate{id: :solid}, _context), do: PredicateResult.pass(%{ok: true})
  end

  defmodule NoopHarness do
    @moduledoc false
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{output: "ok", cost: %{tokens: 0}}}
  end

  defmodule NoopIntegrate do
    @moduledoc false
    @behaviour Action

    @impl true
    def execute(%Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule NoopDeploy do
    @moduledoc false
    @behaviour Action

    @impl true
    def execute(%Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  test "a quarantined (flaky) predicate never lets the run report :converged, even with every other predicate genuinely green" do
    {:ok, flaky_pid} = FlakyProvider.start_link(nil)

    goal =
      Goal.new("verdict-bar-i795",
        predicates: [Predicate.new(:flaky, :tests), Predicate.new(:solid, :solid_tests)],
        metadata: %{flaky_pid: flaky_pid}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: FlakyProvider, solid_tests: SolidProvider},
        harness: NoopHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        workspace: "/fixture/ws",
        flake_max_retries: 2,
        reobserve_interval_ms: 5,
        stuck_iterations: 0
      )

    # #820: `stuck_iterations: 0` disables the ORDINARY (T1.5) stuck detector, but
    # `:flaky` never rehabilitates here (it keeps alternating fail/pass on every
    # real re-poll, never stringing together `Kazi.Loop.Flake.rehab_streak/0`
    # consecutive passes) — the vector stays blocked SOLELY by quarantine with
    # nothing dispatchable, so the independent honest-termination path stops the
    # loop `:stuck` rather than idling at the reobserve interval forever (the
    # pre-#820 bug this suite's moduledoc predates: it used to assert
    # `{:error, :timeout}` here, i.e. the loop never terminating at all).
    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    refute result.outcome == :converged
    assert result.outcome == :stopped
    assert result.reason == :stuck

    snap = Kazi.Loop.snapshot(loop)
    assert :flaky in snap.quarantine, "the alternating predicate must be quarantined as flaky"

    refute :dispatch_agent in snap.actions,
           "a quarantined predicate must not be re-dispatched as work"
  end

  # ===========================================================================
  # Point (2) of the #795 fix: a quarantine mechanism must NAME the quarantined
  # predicate ids in a dedicated field on the terminal result, rather than
  # silently widening the convergence bar. Reached here via a :stuck stop (a
  # second, consistently-failing predicate drives the stuck detector) so there
  # IS a terminal result to inspect — see `Kazi.Loop.result/0`'s `:quarantine`.
  # ===========================================================================

  defmodule FailingProvider do
    @moduledoc false
    @behaviour PredicateProvider

    @impl true
    def evaluate(%Predicate{id: :broken}, _context),
      do: PredicateResult.fail(%{output: "expected 200 got 404"})
  end

  test "the terminal result names quarantined predicate ids in a dedicated field" do
    {:ok, flaky_pid} = FlakyProvider.start_link(nil)

    goal =
      Goal.new("verdict-bar-i795-quarantine-field",
        predicates: [Predicate.new(:flaky, :tests), Predicate.new(:broken, :broken_tests)],
        metadata: %{flaky_pid: flaky_pid}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: FlakyProvider, broken_tests: FailingProvider},
        harness: NoopHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        workspace: "/fixture/ws",
        flake_max_retries: 2,
        reobserve_interval_ms: 5,
        stuck_iterations: 2
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :stopped
    assert result.reason == :stuck

    assert result.quarantine == [:flaky],
           "the terminal result must name the quarantined predicate id, not just its effect"
  end
end

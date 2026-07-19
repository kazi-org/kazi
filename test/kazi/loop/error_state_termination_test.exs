defmodule Kazi.Loop.ErrorStateTerminationTest do
  @moduledoc """
  M5 (deep-review-001): a predicate persistently stuck in `:error` (a
  checker-unrunnable condition — a broken provider, a custom_script emitting
  non-JSON, a checker that always times out) TERMINATES the loop instead of
  re-observing forever with no budget. Mirrors `Kazi.StuckLoopTest` (the ordinary
  `:fail`-based stuck stop) but with an always-`:error` provider and NO
  `[budget]` table, so the stuck-on-error path is the ONLY terminator available.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Action, Goal, Predicate, PredicateResult}

  # A provider whose predicate is ALWAYS :error, so it never converges (requires
  # :pass), never dispatches (PredicateVector.failing/1 matches only :fail), and
  # never trips the ordinary :fail-based stuck check.
  defmodule AlwaysErrorProvider do
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

  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  defp always_error_goal do
    Goal.new("error-stuck-test", predicates: [Predicate.new(:code, :tests)])
  end

  defp start_loop(opts) do
    base = [
      goal: always_error_goal(),
      providers: %{tests: AlwaysErrorProvider},
      harness: NoopHarness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      reobserve_interval_ms: 1,
      flake_max_retries: 0
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  test "a persistent :error across N iterations stops the loop, not an infinite spin" do
    {:ok, loop} = start_loop(stuck_iterations: 3, on_escalation: fn _ -> :ok end)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :stopped
    assert result.reason == :stuck
    assert result.iterations == 3

    snap = Kazi.Loop.snapshot(loop)
    assert snap.state == :stopped
    assert snap.stuck_failing == [:code]
  end

  test "the error-stuck stop is a HARD stop: further awaits return the same cached result" do
    {:ok, loop} = start_loop(stuck_iterations: 2, on_escalation: fn _ -> :ok end)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :stopped
    assert result.reason == :stuck

    assert {:ok, ^result} = Kazi.Loop.await(loop, 1_000)
    assert Kazi.Loop.snapshot(loop).state == :stopped
  end

  test "a MIX of a genuinely failing predicate and a persistently erroring one still stops" do
    defmodule MixedProvider do
      @behaviour Kazi.PredicateProvider

      @impl true
      def evaluate(%Predicate{id: :ok_fail}, _context),
        do: PredicateResult.fail(%{status: :fail})

      def evaluate(%Predicate{id: :broken}, _context),
        do: PredicateResult.error(%{reason: :checker_unrunnable})
    end

    goal =
      Goal.new("mixed-error-test",
        predicates: [
          Predicate.new(:ok_fail, :tests),
          Predicate.new(:broken, :tests)
        ]
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: MixedProvider},
        harness: NoopHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        reobserve_interval_ms: 1,
        flake_max_retries: 0,
        stuck_iterations: 3,
        on_escalation: fn _ -> :ok end
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :stopped
    assert result.reason == :stuck
  end
end

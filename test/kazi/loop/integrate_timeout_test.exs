defmodule Kazi.Loop.IntegrateTimeoutTest do
  @moduledoc """
  issue #1020: a `kazi apply` run reached the `:integrate` ACT clause and
  stalled forever — alive, 0% CPU, no children, no sockets, no forward
  progress — because `handle_event/4` called the injected integrator's
  `execute/2` in-process with no timeout. Proves the fix: a hanging
  integrator is bounded by `:integrate_timeout_ms` and the loop stays
  responsive (bounded total run time) instead of wedging forever.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Budget, Goal, Predicate, PredicateResult}

  defmodule AlwaysPassProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, _context), do: PredicateResult.new(:pass, %{id: id})
  end

  # A live predicate that never passes (deploy never happens — integrate never
  # gets past the hang), so `decide/2` never reaches `all_satisfied?` and keeps
  # routing back through the `:integrate` ACT clause every tick, exactly the
  # real-world shape (a live check gating on a landed+deployed change).
  defmodule NeverPassProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, _context), do: PredicateResult.new(:fail, %{id: id})
  end

  # The stalled real-world integrator: never returns, exactly the observed
  # symptom (alive, 0% CPU, no forward progress).
  defmodule HangingIntegrate do
    @behaviour Kazi.Action

    @impl true
    def execute(_action, _context) do
      Process.sleep(:infinity)
    end
  end

  defmodule NoopAction do
    @behaviour Kazi.Action

    @impl true
    def execute(_action, _context), do: {:ok, %{}}
  end

  # Never invoked (code is always green so nothing is ever dispatched), but a
  # `Kazi.Loop` still requires a `:harness` implementation to boot.
  defmodule UnusedHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{output: "", cost: %{tokens: 0}}}
  end

  defp goal do
    Goal.new("loop-integrate-timeout-test",
      predicates: [Predicate.new(:code, :tests), Predicate.new(:live_check, :http_probe)]
    )
  end

  test "a hanging integrator is bounded by :integrate_timeout_ms, not left to wedge the loop" do
    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal(),
        providers: %{tests: AlwaysPassProvider, live_check: NeverPassProvider},
        harness: UnusedHarness,
        integrate: HangingIntegrate,
        deploy: NoopAction,
        integrate_timeout_ms: 20,
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0,
        budget: %Budget{max_iterations: 3}
      )

    # Bounded wait: proves the loop actually comes back instead of hanging.
    # Without the fix this `await` itself would time out (the gen_statem never
    # replies because it never leaves the `:acting` state).
    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    # Code stayed green the whole time, but every integrate attempt timed out,
    # so the run never lands and stops the moment its (tiny) budget is spent —
    # never a silent infinite retry, never a wedge.
    assert result.outcome == :over_budget
    assert result.reason == :max_iterations
    assert :integrate in result.actions
  end
end

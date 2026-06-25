defmodule Kazi.Loop.StuckBundleTest do
  @moduledoc """
  T35.6: a stuck run surfaces a bounded `stuck_bundle` on the result (failing
  predicates + changed files + budget-fitted store snippets), so the ADR-0035
  escalation hands the higher rung the bundle, not the full transcript.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate, PredicateResult}

  # Fails forever with a fixed evidence blob, so the same failing set persists and
  # the loop stops :stuck after the stuck window.
  defmodule StuckProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, context),
      do: PredicateResult.fail(%{id: id, output: context.goal.metadata.evidence})
  end

  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _ws, _opts), do: {:ok, %{output: "ok", cost: %{tokens: 1}}}
  end

  defmodule NoopAction do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{}, _ctx), do: {:ok, %{}}
  end

  test "a stuck run produces a bounded stuck_bundle naming the failing predicates" do
    goal =
      Goal.new("stuck-bundle-test",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{evidence: "expected 200 got 404\n" <> String.duplicate("trace line\n", 50)}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: StuckProvider},
        harness: RecordingHarness,
        integrate: NoopAction,
        deploy: NoopAction,
        adapter_opts: [],
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        # stop :stuck after the same failing set persists across 2 observations.
        stuck_iterations: 2
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :stopped
    assert result.reason == :stuck

    bundle = result.stuck_bundle
    assert is_map(bundle)
    assert [%{"id" => "code", "failure" => failure}] = bundle["failing_predicates"]
    assert failure =~ "404"
    assert is_integer(bundle["bytes"]) and bundle["bytes"] > 0
    # No store configured → no snippets, but the bundle still carries the signal.
    assert bundle["snippets"] == []
  end

  test "a non-stuck terminal result carries NO stuck_bundle" do
    # A predicate that passes immediately → :converged, never stuck.
    goal =
      Goal.new("converges",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{evidence: "n/a"}
      )

    defmodule PassProvider do
      @behaviour Kazi.PredicateProvider
      @impl true
      def evaluate(%Predicate{id: id}, _ctx), do: PredicateResult.pass(%{id: id})
    end

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: PassProvider},
        harness: RecordingHarness,
        integrate: NoopAction,
        deploy: NoopAction,
        adapter_opts: [],
        reobserve_interval_ms: 5
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :converged
    refute Map.has_key?(result, :stuck_bundle)
  end
end

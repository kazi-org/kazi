defmodule Kazi.Loop.ContextTierTest do
  @moduledoc """
  T36.3 (ADR-0047 §2/§3): a real `Kazi.Loop` dispatch DEFAULTS to context tier 1,
  RECORDS the active tier per iteration in the ADR-0046 `context` envelope, and
  tier selection CHANGES the assembled context:

    * tier 0 (evidence-only) DROPS the cached orientation prefix from the prompt;
    * tier 1 (default) keeps it;
    * tier 2 ADDS the live code-review-graph MCP server back into the dispatch
      tool/MCP surface (the surface a Claude-profile dispatch receives).

  Drives a loop with a hermetic `Kazi.Context.StaticGraphSource` (no filesystem /
  network) and a recording harness that forwards both the prompt and the resolved
  adapter opts, plus an `on_iteration` collector for the recorded tier.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Context.StaticGraphSource
  alias Kazi.Harness.Registry

  # A code predicate provider scripted per id (fail…, then pass), so the loop
  # dispatches before converging.
  defmodule ScriptedProvider do
    @behaviour Kazi.PredicateProvider
    use Agent

    def start_link(script) when is_map(script), do: Agent.start_link(fn -> script end)

    @impl true
    def evaluate(%Predicate{id: id}, context) do
      pid = context.goal.metadata.script_pid

      status =
        Agent.get_and_update(pid, fn script ->
          case Map.get(script, id, [:pass]) do
            [last] -> {last, %{script | id => [last]}}
            [next | rest] -> {next, %{script | id => rest}}
          end
        end)

      Kazi.PredicateResult.new(status, %{output: "boom in lib/widget.ex"})
    end
  end

  # Harness double: forwards the dispatch prompt AND the resolved adapter opts to
  # the collector, so the test can inspect both the prompt (orientation presence)
  # and the tool/MCP surface (graph server presence) the dispatch carried.
  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(prompt, _workspace, opts) do
      send(Keyword.fetch!(opts, :collector), {:dispatched, prompt, opts})
      {:ok, %{output: "ok", cost: %{tokens: 1}, touched: ["lib/widget.ex"]}}
    end
  end

  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  @graph_source StaticGraphSource.new(
                  origin: :graph,
                  files: ["lib/widget.ex", "lib/other.ex"],
                  symbols: [{"render_widget/1", "lib/widget.ex", callers: ["page/0"]}],
                  test_sources: [{"test/widget_test.exs", source: "assert Widget.render(1)"}]
                )

  # Run a loop that fails the code predicate once then passes (one dispatch),
  # threading the hermetic graph source plus any extra adapter opts. Returns
  # `{dispatched_opts, iteration_events}`.
  defp run(adapter_extra) do
    {:ok, script_pid} = ScriptedProvider.start_link(%{code: [:fail, :pass]})
    test = self()

    goal =
      Goal.new("context-tier-test",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{script_pid: script_pid}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: ScriptedProvider},
        harness: RecordingHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        workspace: "/fixture/ws",
        adapter_opts: [collector: test, graph_source: @graph_source] ++ adapter_extra,
        on_iteration: fn payload -> send(test, {:iteration, payload}) end,
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0
      )

    {:ok, _result} = Kazi.Loop.await(loop, 5_000)
    {collect_dispatch(), collect_iterations([])}
  end

  defp collect_dispatch do
    receive do
      {:dispatched, prompt, opts} -> {prompt, opts}
    after
      500 -> flunk("expected a dispatch")
    end
  end

  defp collect_iterations(acc) do
    receive do
      {:iteration, payload} -> collect_iterations([payload | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  describe "default tier" do
    test "a dispatch DEFAULTS to tier 1: orientation present, tier 1 recorded per iteration" do
      {{prompt, _opts}, events} = run([])

      # Tier 1 keeps the cached orientation prefix (default behaviour, T19.1).
      assert prompt =~ "# Orientation"
      assert prompt =~ "lib/widget.ex"

      # The dispatch's iteration (#1) records the active tier as 1.
      dispatch_event = Enum.find(events, &(&1.iteration == 1))
      assert dispatch_event.context.tier == 1
    end
  end

  describe "tier 0 — evidence only" do
    test "tier 0 DROPS the cached orientation prefix and records tier 0" do
      {{prompt, _opts}, events} = run(context_tier: 0)

      # The orientation prefix is gone — the prompt begins at the evidence body.
      refute prompt =~ "# Orientation"
      assert String.starts_with?(prompt, "goal=context-tier-test fix failing predicates: code")

      dispatch_event = Enum.find(events, &(&1.iteration == 1))
      assert dispatch_event.context.tier == 0
    end
  end

  describe "tier 2 — adds the live graph MCP surface" do
    test "tier 1 (default) EXCLUDES the graph MCP server from the surface" do
      {:ok, profile} = Registry.fetch(:claude)
      {{_prompt, opts}, events} = run(profile: profile)

      refute "mcp__code-review-graph" in Keyword.get(opts, :tools, [])
      assert Keyword.get(opts, :mcp_config) == []

      assert Enum.find(events, &(&1.iteration == 1)).context.tier == 1
    end

    test "tier 2 ADDS the graph MCP server to the surface and records tier 2" do
      {:ok, profile} = Registry.fetch(:claude)
      {{_prompt, opts}, events} = run(profile: profile, context_tier: 2)

      assert "mcp__code-review-graph" in Keyword.get(opts, :tools, [])
      assert Keyword.get(opts, :mcp_config) == ["/fixture/ws/.mcp.json"]

      assert Enum.find(events, &(&1.iteration == 1)).context.tier == 2
    end
  end
end

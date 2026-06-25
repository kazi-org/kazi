defmodule Kazi.Loop.IterationCountersTest do
  @moduledoc """
  T34.3 (ADR-0046 §2): a real `Kazi.Loop` dispatch records the per-iteration
  `context` + `tools` counters in the iteration event (the `:on_iteration` seam),
  so the E19 token-economy arms can attribute outcomes to them.

  Drives a loop that fails the same code predicate TWICE (an unchanged blast
  radius ⇒ a byte-identical orientation prefix) then passes, capturing each
  `on_iteration` payload. Asserts:

    * the first observation (no preceding dispatch) carries the all-disabled / zero
      context and no tool counters;
    * the dispatch's context carries real per-section token estimates and the
      orientation cache flips `miss → hit` across the two same-blast-radius
      dispatches (the falsifiable stable-prefix signal, ADR-0010/0045);
    * the `tools` counters are parsed from the harness's tool-use stream.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Context.StaticGraphSource

  # Scripted code provider: pops the next status per id, holding the last forever
  # (so "fail, fail, pass" drives two dispatches before converging).
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

  # Harness double: reports a touched working set AND a tool-use stream, so the
  # loop derives non-empty `tools` counters from a real result field.
  defmodule ToolReportingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts) do
      {:ok,
       %{
         output: "ok",
         cost: %{tokens: 1},
         touched: ["lib/widget.ex"],
         tool_uses: ["Read", "Read", "Grep", "mcp__code-review-graph__query_graph"]
       }}
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

  defp run_loop(script) do
    {:ok, script_pid} = ScriptedProvider.start_link(script)
    test = self()

    goal =
      Goal.new("iter-counters-test",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{script_pid: script_pid}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: ScriptedProvider},
        harness: ToolReportingHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        workspace: "/fixture/ws",
        adapter_opts: [graph_source: @graph_source],
        on_iteration: fn payload -> send(test, {:iteration, payload}) end,
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0
      )

    {:ok, _result} = Kazi.Loop.await(loop, 5_000)
    collect_iterations([])
  end

  defp collect_iterations(acc) do
    receive do
      {:iteration, payload} -> collect_iterations([payload | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  test "each iteration event carries the context + tool counters; the orientation cache flips miss→hit" do
    events = run_loop(%{code: [:fail, :fail, :pass]})

    # Three observations: fail (dispatch 1), fail (dispatch 2), pass (converge).
    assert length(events) == 3
    [first, second, third] = events

    # --- Iteration 0: no preceding dispatch → all-disabled / zero context, no tools.
    assert first.iteration == 0
    assert first.context.orientation_cache == "disabled"
    assert first.context.orientation_tokens == 0
    assert first.context.evidence_tokens == 0
    assert first.tools == %{}

    # --- Iteration 1: the FIRST dispatch's context. A real orientation prefix was
    # sent (graph present) but there is no prior to match → a cache miss; the
    # evidence section carries real tokens; the tool stream classifies.
    assert second.iteration == 1
    assert second.context.orientation_cache == "miss"
    assert second.context.orientation_tokens > 0
    assert second.context.evidence_tokens > 0

    assert second.tools == %{
             tool_calls: 4,
             file_reads: 2,
             search_calls: 1,
             graph_calls: 1
           }

    # --- Iteration 2: the SECOND dispatch's context. Same failing set ⇒ same blast
    # radius ⇒ a byte-identical orientation prefix the inner harness's cache hits.
    assert third.iteration == 2
    assert third.context.orientation_cache == "hit"
    assert third.context.orientation_tokens == second.context.orientation_tokens
  end

  test "with no graph/repo-map the orientation cache is disabled but evidence tokens still record" do
    {:ok, script_pid} = ScriptedProvider.start_link(%{code: [:fail, :pass]})
    test = self()

    goal =
      Goal.new("iter-counters-nograph",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{script_pid: script_pid}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: ScriptedProvider},
        harness: ToolReportingHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        # No graph_source ⇒ no orientation prefix is built.
        workspace: "/fixture/ws",
        on_iteration: fn payload -> send(test, {:iteration, payload}) end,
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0
      )

    {:ok, _result} = Kazi.Loop.await(loop, 5_000)
    [_first, second | _] = collect_iterations([])

    assert second.context.orientation_cache == "disabled"
    assert second.context.orientation_tokens == 0
    # The evidence section is always sent, so it always carries a real token count.
    assert second.context.evidence_tokens > 0
  end
end

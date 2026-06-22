defmodule Kazi.Loop.WorkspacePrepTest do
  @moduledoc """
  Wiring test for T4.5 (ADR-0010 §3): the loop runs `Kazi.Workspace.prepare/2`
  against the target workspace BEFORE it dispatches the harness, exposing the
  code-review-graph MCP in `.mcp.json` and (when a graph is present) refreshing
  it via the injected `:graph_cmd` seam. Fully hermetic — a recording harness
  double and a stub graph command; no real `claude` or `code-review-graph`.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Kazi.{Goal, Predicate}

  # A provider that reports a code predicate failing once (so the loop dispatches
  # the agent), then passing (so the loop converges and stops). One status per
  # observation.
  defmodule OnceFailingProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(_predicate, %{iteration: 0}), do: Kazi.PredicateResult.fail(%{output: "red"})
    def evaluate(_predicate, _context), do: Kazi.PredicateResult.pass()
  end

  # A harness double that, when dispatched, records that it ran and asserts the
  # workspace was already prepared (the .mcp.json exists by the time we run).
  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, workspace, opts) do
      mcp_present? = File.exists?(Path.join(workspace, ".mcp.json"))
      send(Keyword.fetch!(opts, :collector), {:dispatched, mcp_present?})
      {:ok, %{output: "ok", exit: 0}}
    end
  end

  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(_action, _context), do: {:ok, %{}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(_action, _context), do: {:ok, %{}}
  end

  test "loop prepares the workspace (mcp + graph freshness) before dispatching", %{tmp_dir: dir} do
    # Seed a fake graph so the freshness step engages and exercises the seam.
    db_dir = Path.join(dir, ".code-review-graph")
    File.mkdir_p!(db_dir)
    File.write!(Path.join(db_dir, "graph.db"), "")

    {:ok, graph_log} = Agent.start_link(fn -> [] end)

    graph_cmd = fn args, _opts ->
      Agent.update(graph_log, &(&1 ++ [args]))
      {"clean\n", 0}
    end

    goal =
      Goal.new("loop-prep-test", predicates: [Predicate.new(:code, :tests)])

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: OnceFailingProvider},
        harness: RecordingHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        workspace: dir,
        adapter_opts: [collector: self()],
        workspace_opts: [graph_cmd: graph_cmd],
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0
      )

    on_exit(fn -> if Process.alive?(loop), do: Kazi.Loop.stop(loop) end)

    # The dispatch ran and saw the workspace already prepared (.mcp.json present).
    assert_receive {:dispatched, true}, 1_000

    # The .mcp.json carries the graph MCP server.
    config = dir |> Path.join(".mcp.json") |> File.read!() |> Jason.decode!()
    assert config["mcpServers"]["code-review-graph"]["command"] == "code-review-graph"

    # The injected graph seam ran detect-changes for freshness (no real binary).
    calls = Agent.get(graph_log, & &1)
    assert ["detect-changes", "--brief"] in calls
  end
end

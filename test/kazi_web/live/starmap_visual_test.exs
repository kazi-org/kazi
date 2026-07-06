defmodule KaziWeb.StarmapVisualTest do
  @moduledoc """
  Structural regression pinning the approved starmap visual design
  (ADR-0057, `docs/dashboard-design.md`) across the three dashboard pages it
  maps onto: the rail + wave-band canvas + event river on `StarmapLive`, the
  DNA-strip + heatmap on `DrillinHeatmapLive`, and the tool pills on
  `TranscriptPeekLive`.

  This is a STRUCTURE pin, not a pixel test: it asserts the spec's named
  elements exist and carry the right state-addressable data attributes/CSS
  classes (the "node state zoo"), not exact colors or layout geometry (those
  are covered by `design_tokens_present`/`node_state_zoo_present` grepping the
  goal-file drives directly). Every state stays data-attribute-addressable, so
  `StarmapLiveTest`/`StarmapWavebandTest`/`DrillinHeatmapLiveTest`/
  `TranscriptPeekLiveTest` keep passing unmodified.
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.{Action, PredicateResult, PredicateVector, ReadModel}
  alias Kazi.Goal
  alias Kazi.Goal.Group
  alias Kazi.ReadModel.RunRegistry

  defmodule StubGoalSource do
    @moduledoc "Test fixture mirroring `KaziWeb.StarmapWavebandTest`'s stub."
    @behaviour KaziWeb.Starmap.GoalSource

    @impl true
    def goal, do: Application.get_env(:kazi, :starmap_visual_stub_goal)
  end

  setup do
    Application.put_env(:kazi, :starmap_goal_source, StubGoalSource)

    on_exit(fn ->
      Application.delete_env(:kazi, :starmap_goal_source)
      Application.delete_env(:kazi, :starmap_visual_stub_goal)
    end)

    :ok
  end

  defp put_goal(goal), do: Application.put_env(:kazi, :starmap_visual_stub_goal, goal)

  defp chain_goal do
    Goal.new("roadmap",
      groups: [
        Group.new("a", "Goal A"),
        Group.new("b", "Goal B", needs: ["a"]),
        Group.new("c", "Goal C", needs: ["b"])
      ]
    )
  end

  defp seed(goal_ref, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          run_id: "run-#{System.unique_integer([:positive])}",
          pid: "#PID<0.1.0>",
          workspace: "/tmp/ws",
          goal_ref: goal_ref,
          harness: "claude",
          model: "claude-sonnet-5"
        },
        overrides
      )

    {:ok, run} = RunRegistry.start(attrs)
    run
  end

  describe "starmap: rail, legend, wave-band canvas, event river" do
    test "the rail carries FLEET stat tiles and the attention rail section", %{conn: conn} do
      run = seed("goal-one")
      {:ok, _} = RunRegistry.finish(run.run_id, "stuck")

      {:ok, _view, html} = live(conn, ~p"/starmap")

      assert html =~ ~s(id="starmap-rail")
      assert html =~ ~s(id="starmap-fleet-tiles")
      assert html =~ ~s(data-tile="running")
      assert html =~ ~s(data-tile="landed")
      assert html =~ ~s(data-tile="stuck")
      assert html =~ ~s(id="starmap-rail-attention")
    end

    test "the LEGEND lists all six node states", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/starmap")

      assert html =~ ~s(id="starmap-legend")

      for state <- ~w(landed converging stuck claimed pending stale) do
        assert html =~ ~s(data-state="#{state}")
      end

      for class <- ~w(nd-landed nd-conv nd-stuck nd-claimed nd-pending nd-stale) do
        assert html =~ class
      end
    end

    test "the wave-band SVG canvas renders per-state node classes and session tags on active nodes",
         %{conn: conn} do
      put_goal(chain_goal())
      run_a = seed("a")
      {:ok, _} = RunRegistry.finish(run_a.run_id, "converged")

      {:ok, _view, html} = live(conn, ~p"/starmap")

      assert html =~ ~s(id="starmap-canvas")
      assert html =~ ~s(class="starmap-canvas")

      # a: landed: b: claimed (eligible, active): c: pending.
      assert html =~ ~s(id="canvas-node-a" class="canvas-node nd-landed")
      assert html =~ ~s(id="canvas-node-b" class="canvas-node nd-claimed")
      assert html =~ ~s(id="canvas-node-c" class="canvas-node nd-pending")

      # The active (claimed) node carries a session tag; the pending one does not.
      assert html =~ ~s(data-node-id="b" data-frontier="1" data-state="claimed")
      assert html =~ "S1"
    end

    test "a stuck run keeps its session visible: SESSIONS section with a red chip", %{conn: conn} do
      run = seed("wedged-goal")
      {:ok, _} = RunRegistry.finish(run.run_id, "stuck")

      {:ok, _view, html} = live(conn, ~p"/starmap")

      # The mockup's S2: a stuck goal's driving session stays listed in the
      # rail (red chip variant), so a fleet with zero RUNNING but stuck work
      # still shows WHO was driving what.
      assert html =~ ~s(id="starmap-sessions")
      assert html =~ "SESSIONS"
      assert html =~ ~s(class="session-id red")
      assert html =~ "wedged-goal"
    end

    test "a session row shows the operator-assigned session name and workspace basename",
         %{conn: conn} do
      seed("named-goal", %{
        session_name: "starmap-pass-3",
        workspace: "/Users/op/wt/kazi-t99"
      })

      {:ok, _view, html} = live(conn, ~p"/starmap")

      # The name replaces the generic harness label; the workspace basename
      # rides alongside as the tiebreaker for same-repo sessions.
      assert html =~ "starmap-pass-3 · driving"
      assert html =~ "kazi-t99"
    end

    test "the bottom event-river bar renders", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/starmap")

      assert html =~ ~s(id="starmap-event-river")
      assert html =~ "EVENT RIVER"
    end

    test "existing data-attribute assertions from StarmapLiveTest/StarmapWavebandTest still hold",
         %{conn: conn} do
      put_goal(chain_goal())
      run = seed("a")
      {:ok, _} = RunRegistry.finish(run.run_id, "converged")

      {:ok, _view, html} = live(conn, ~p"/starmap")

      assert html =~ ~s(id="canvas-node-a")
      assert html =~ ~s(data-node-id="a" data-frontier="0" data-state="landed")
    end
  end

  describe "drill-in: DNA strip" do
    defp record(goal_ref, index, vector) do
      {:ok, iteration} =
        ReadModel.record_iteration(%{
          goal_ref: goal_ref,
          iteration_index: index,
          predicate_vector: vector,
          action: Action.new(:dispatch_agent, params: %{})
        })

      iteration
    end

    defp vector(unit_status, probe_status) do
      PredicateVector.new(%{
        unit: PredicateResult.new(unit_status, %{exit: 0}),
        probe: PredicateResult.new(probe_status, %{http_status: 200})
      })
    end

    test "renders a predicate-vector DNA strip for the latest iteration", %{conn: conn} do
      record("dna-goal", 0, vector(:fail, :fail))
      record("dna-goal", 1, vector(:pass, :fail))

      {:ok, _view, html} = live(conn, ~p"/goals/dna-goal/drillin")

      assert html =~ ~s(id="drillin-dna-strip")
      assert html =~ "PREDICATE VECTOR"
      assert html =~ ~s(id="dna-square-unit" class="dna-square status-pass")
      assert html =~ ~s(id="dna-square-probe" class="dna-square status-fail")

      # The heatmap (existing structure) still renders alongside it.
      assert html =~ ~s(id="heatmap-row-unit")
    end
  end

  describe "transcript peek: tool pills" do
    @moduletag :tmp_dir

    test "tool events render as bordered pills", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "transcript-#{System.unique_integer([:positive])}.jsonl")

      {:ok, run} =
        RunRegistry.start(%{
          run_id: "run-#{System.unique_integer([:positive])}",
          pid: "#PID<0.1.0>",
          workspace: "/tmp/ws",
          goal_ref: "goal-#{System.unique_integer([:positive])}",
          harness: "claude",
          model: "claude-sonnet-5",
          transcript_sink_path: path
        })

      File.write!(
        path,
        Jason.encode!(%{
          "type" => "tool_use",
          "name" => "Bash",
          "input" => %{"cmd" => "mix test"}
        }) <>
          "\n"
      )

      {:ok, _view, html} = live(conn, ~p"/runs/#{run.run_id}/transcript")

      assert html =~ ~s(class="tool-pill")
      assert html =~ "Bash"
      assert html =~ "tool-pill-marker"
    end
  end
end

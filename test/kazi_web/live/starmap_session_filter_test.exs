defmodule KaziWeb.StarmapSessionFilterTest do
  @moduledoc """
  LiveView test for the SESSIONS rail filter: clicking a session row dims the
  constellation to that session's goal (nodes AND edges), clicking the same
  row again clears the filter, and a filter whose session ended clears
  itself on the next tick instead of dimming the canvas against a node that
  no longer carries the tag.
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.Goal
  alias Kazi.Goal.Group
  alias Kazi.ReadModel.RunRegistry

  defmodule StubGoalSource do
    @moduledoc "Test fixture mirroring `KaziWeb.StarmapWavebandTest`'s stub."
    @behaviour KaziWeb.Starmap.GoalSource

    @impl true
    def goal, do: Application.get_env(:kazi, :starmap_session_filter_stub_goal)
  end

  setup do
    Application.put_env(:kazi, :starmap_goal_source, StubGoalSource)

    on_exit(fn ->
      Application.delete_env(:kazi, :starmap_goal_source)
      Application.delete_env(:kazi, :starmap_session_filter_stub_goal)
    end)

    :ok
  end

  defp put_goal(goal) do
    Application.put_env(:kazi, :starmap_session_filter_stub_goal, goal)
  end

  defp seed(goal_ref) do
    {:ok, run} =
      RunRegistry.start(%{
        run_id: "run-#{goal_ref}",
        pid: "#PID<0.1.0>",
        workspace: "/tmp/ws",
        goal_ref: goal_ref,
        harness: "claude",
        model: "claude-sonnet-5",
        session_os_pid: "424242"
      })

    run
  end

  # Two independent chains (a -> b, c -> d) so a filter on one chain's node
  # leaves an edge that must dim (the other chain's).
  defp two_chain_goal do
    Goal.new("roadmap",
      groups: [
        Group.new("a", "Goal A"),
        Group.new("b", "Goal B", needs: ["a"]),
        Group.new("c", "Goal C"),
        Group.new("d", "Goal D", needs: ["c"])
      ]
    )
  end

  test "clicking a session row filters: other nodes and unrelated edges dim, the row goes active",
       %{conn: conn} do
    put_goal(two_chain_goal())

    for ref <- ["a", "c"] do
      run = seed(ref)
      {:ok, _} = RunRegistry.finish(run.run_id, "converged")
    end

    # b converging -> tagged S1; d claimed -> also tagged.
    seed("b")

    {:ok, view, html} = live(conn, ~p"/starmap")
    refute html =~ "data-session-filter"

    html = view |> element(~s(.session-row[data-session="S1"])) |> render_click()

    assert html =~ ~s(data-session-filter="S1")
    assert html =~ ~s(class="session-row active")

    # b keeps full opacity; every other node dims.
    refute html =~ ~s(id="canvas-node-group-b" class="canvas-node-group dimmed")
    assert html =~ ~s(id="canvas-node-group-a" class="canvas-node-group dimmed")
    assert html =~ ~s(id="canvas-node-group-c" class="canvas-node-group dimmed")
    assert html =~ ~s(id="canvas-node-group-d" class="canvas-node-group dimmed")

    # The edge touching b stays; the other chain's edge dims.
    assert html =~ ~s(class="edge edge-active" data-from="a" data-to="b")
    assert html =~ ~s(class="edge dimmed" data-from="c" data-to="d")
  end

  test "clicking the active session row again clears the filter", %{conn: conn} do
    put_goal(nil)
    seed("solo-goal")

    {:ok, view, _html} = live(conn, ~p"/starmap")

    html = view |> element(~s(.session-row[data-session="S1"])) |> render_click()
    assert html =~ ~s(data-session-filter="S1")

    html = view |> element(~s(.session-row[data-session="S1"])) |> render_click()
    refute html =~ "data-session-filter"
    refute html =~ ~s(class="canvas-node-group dimmed")
  end

  test "a filter whose session ended clears itself on the next tick", %{conn: conn} do
    put_goal(nil)
    run = seed("ending-goal")

    {:ok, view, _html} = live(conn, ~p"/starmap")

    html = view |> element(~s(.session-row[data-session="S1"])) |> render_click()
    assert html =~ ~s(data-session-filter="S1")

    # The run lands: its node loses the tag, so the filter must clear rather
    # than dim the whole canvas.
    {:ok, _} = RunRegistry.finish(run.run_id, "converged")
    send(view.pid, :tick)
    html = render(view)

    refute html =~ "data-session-filter"
    refute html =~ ~s(class="canvas-node-group dimmed")
  end
end

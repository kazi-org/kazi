defmodule Kazi.Scheduler.FrontierCompleteEventTest do
  @moduledoc """
  Issue #936 acceptance (minimal slice): under a multi-frontier `needs`-DAG, the
  `DepScheduler` fires the OPT-IN `:on_frontier_complete` callback once per
  topological frontier as it fully settles, and it fires BEFORE the next
  frontier's groups dispatch. This is the seam the CLI's `apply --parallel --json
  --stream` path wires into a JSONL `"event": "frontier_complete"` line
  (`Kazi.CLI`'s `maybe_put_frontier_stream/2` / `emit_frontier_complete_event/1`).

  Hermetic throughout: an injected stub reconciler drives convergence, gated on a
  `release` message so the test controls exactly when each group terminates and
  can assert the frontier event lands at the right instant relative to dispatch.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Group
  alias Kazi.Scheduler.DepScheduler
  alias Kazi.Scheduler.PartitionSupervisor

  setup do
    {:ok, sup} = start_supervised(PartitionSupervisor)
    %{sup: sup}
  end

  # Two independent groups (a, b) at frontier 0; c at frontier 1, needing BOTH a
  # and b (so c's readiness is genuinely gated on the whole of frontier 0 — no
  # race between "frontier 0 settled" and "c becomes ready").
  defp two_frontier_goal do
    Goal.new("multi-frontier",
      groups: [
        Group.new("a", "A"),
        Group.new("b", "B"),
        Group.new("c", "C", needs: ["a", "b"])
      ]
    )
  end

  # A reconciler stub that announces its own dispatch, then blocks until released
  # with a chosen terminal status — lets the test pin the exact convergence order.
  defp gated_reconciler(test_pid) do
    fn group_id ->
      send(test_pid, {:dispatched, group_id, self()})

      receive do
        {:release, ^group_id, status} -> status
      end
    end
  end

  test "frontier_complete(0) fires after both frontier-0 groups converge and before frontier 1 dispatches",
       %{sup: sup} do
    test_pid = self()
    goal = two_frontier_goal()
    reconciler = gated_reconciler(test_pid)

    stream = fn event -> send(test_pid, {:stream_event, event}) end

    task =
      Task.async(fn ->
        DepScheduler.run(goal,
          reconciler: reconciler,
          supervisor: sup,
          on_frontier_complete: stream
        )
      end)

    assert_receive {:dispatched, "a", a_pid}
    assert_receive {:dispatched, "b", b_pid}
    refute_receive {:dispatched, "c", _}, 30
    refute_receive {:stream_event, _}, 30

    # Converge ONLY a: frontier 0 is not yet fully settled, so no event yet and c
    # (needs BOTH a and b) still does not dispatch.
    send(a_pid, {:release, "a", :converged})
    refute_receive {:stream_event, _}, 30
    refute_receive {:dispatched, "c", _}, 30

    # Converge b: frontier 0 is NOW fully settled — the frontier_complete(0) event
    # must be observed BEFORE c (frontier 1) dispatches.
    send(b_pid, {:release, "b", :converged})

    assert_receive {:stream_event, event0}
    refute_received {:dispatched, "c", _}

    assert event0.event == "frontier_complete"
    assert event0.frontier == 0

    assert Enum.sort_by(event0.groups, & &1.id) == [
             %{id: "a", status: :converged},
             %{id: "b", status: :converged}
           ]

    assert_receive {:dispatched, "c", c_pid}
    send(c_pid, {:release, "c", :converged})

    assert_receive {:stream_event, event1}
    assert event1.event == "frontier_complete"
    assert event1.frontier == 1
    assert event1.groups == [%{id: "c", status: :converged}]

    assert {:ok, result} = Task.await(task)
    assert result.collective == :converged
    assert result.groups == [{"a", :converged}, {"b", :converged}, {"c", :converged}]
  end

  test "the final frontier's event appears before the terminal result", %{sup: sup} do
    test_pid = self()
    goal = two_frontier_goal()
    reconciler = fn _group_id -> :converged end

    stream = fn event -> send(test_pid, {:stream_event, event}) end

    assert {:ok, result} =
             DepScheduler.run(goal,
               reconciler: reconciler,
               supervisor: sup,
               on_frontier_complete: stream
             )

    events = drain_events([])
    assert Enum.map(events, & &1.frontier) == [0, 1]
    assert List.last(events).event == "frontier_complete"
    assert result.collective == :converged
  end

  test "each frontier_complete event object round-trips as valid JSON with the documented fields",
       %{sup: sup} do
    test_pid = self()
    goal = two_frontier_goal()
    reconciler = fn _group_id -> :converged end

    stream = fn event -> send(test_pid, {:stream_event, event}) end

    assert {:ok, _result} =
             DepScheduler.run(goal,
               reconciler: reconciler,
               supervisor: sup,
               on_frontier_complete: stream
             )

    for event <- drain_events([]) do
      encoded = Jason.encode!(event)
      assert {:ok, decoded} = Jason.decode(encoded)

      assert decoded["event"] == "frontier_complete"
      assert is_integer(decoded["frontier"])
      assert is_list(decoded["groups"])

      for group <- decoded["groups"] do
        assert is_binary(group["id"])
        assert is_binary(group["status"])
      end
    end
  end

  test "with no :on_frontier_complete callback, the run behaves exactly as before (no crash, unchanged result)",
       %{sup: sup} do
    goal = two_frontier_goal()
    reconciler = fn _group_id -> :converged end

    assert {:ok, result} = DepScheduler.run(goal, reconciler: reconciler, supervisor: sup)
    assert result.collective == :converged
    assert result.groups == [{"a", :converged}, {"b", :converged}, {"c", :converged}]
  end

  defp drain_events(acc) do
    receive do
      {:stream_event, event} -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

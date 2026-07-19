defmodule Kazi.Scheduler.PauseBetweenWavesTest do
  @moduledoc """
  T50.3 acceptance (ADR-0065 decision 3, issue #936 full ask): a
  `Kazi.Scheduler.DepScheduler` run started with `:pause_between_waves` stops
  dispatching at the first frontier boundary it settles, persists a resume
  checkpoint, and returns a `:paused` collective carrying a `:resume_token`. A
  LATER, SEPARATE call passing `:resume_token` restores the completed groups
  and continues to the collective verdict. A tampered goal between pause and
  resume refuses loudly rather than silently continuing.

  Mirrors `frontier_complete_event_test.exs`'s hermetic setup: a gated stub
  reconciler drives convergence so the test controls exactly when each group
  terminates.
  """
  # Pause persists a checkpoint via `Kazi.Repo` from the DepScheduler's OWN
  # process (not the test process) — `async: false` + SHARED sandbox mode so
  # that write is visible regardless of which process makes it.
  use ExUnit.Case, async: false

  alias Kazi.Goal
  alias Kazi.Goal.Group
  alias Kazi.ReadModel.PauseCheckpointStore
  alias Kazi.Repo
  alias Kazi.Scheduler.DepScheduler
  alias Kazi.Scheduler.PartitionSupervisor

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    # Shared mode is a global switch — restore :manual on exit so it never
    # leaks into concurrently-scheduled async test modules.
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

    {:ok, sup} = start_supervised(PartitionSupervisor)
    %{sup: sup}
  end

  # a, b at frontier 0; c at frontier 1, needing BOTH a and b.
  defp two_frontier_goal do
    Goal.new("multi-frontier",
      groups: [
        Group.new("a", "A"),
        Group.new("b", "B"),
        Group.new("c", "C", needs: ["a", "b"])
      ]
    )
  end

  defp gated_reconciler(test_pid) do
    fn group_id ->
      send(test_pid, {:dispatched, group_id, self()})

      receive do
        {:release, ^group_id, status} -> status
      end
    end
  end

  test "pause_between_waves stops dispatch after the first frontier settles, with a resume handle",
       %{sup: sup} do
    test_pid = self()
    goal = two_frontier_goal()
    reconciler = gated_reconciler(test_pid)

    task =
      Task.async(fn ->
        DepScheduler.run(goal,
          reconciler: reconciler,
          supervisor: sup,
          pause_between_waves: true
        )
      end)

    assert_receive {:dispatched, "a", a_pid}
    assert_receive {:dispatched, "b", b_pid}
    refute_receive {:dispatched, "c", _}, 30

    send(a_pid, {:release, "a", :converged})
    send(b_pid, {:release, "b", :converged})

    assert {:ok, result} = Task.await(task)

    # Frontier 1's group NEVER dispatches.
    refute_received {:dispatched, "c", _}

    assert result.collective == :paused
    assert is_binary(result.resume_token)

    assert Enum.sort(result.groups) == [
             {"a", :converged},
             {"b", :converged},
             {"c", :pending}
           ]

    assert {:ok, checkpoint} = PauseCheckpointStore.fetch(result.resume_token)
    assert checkpoint.goal_hash == PauseCheckpointStore.goal_hash(goal)
  end

  test "resuming with the handle completes the run, matching an unpaused run's union of outcomes",
       %{sup: sup} do
    test_pid = self()
    goal = two_frontier_goal()

    pause_task =
      Task.async(fn ->
        DepScheduler.run(goal,
          reconciler: gated_reconciler(test_pid),
          supervisor: sup,
          pause_between_waves: true
        )
      end)

    assert_receive {:dispatched, "a", a_pid}
    assert_receive {:dispatched, "b", b_pid}
    send(a_pid, {:release, "a", :converged})
    send(b_pid, {:release, "b", :converged})

    assert {:ok, %{collective: :paused, resume_token: token}} = Task.await(pause_task)

    # Resume happens in a SEPARATE scheduler process lifecycle — the checkpoint
    # (read-model), not an in-memory continuation, is what bridges pause->resume.
    resume_reconciler = fn _group_id -> :converged end

    assert {:ok, resumed} =
             DepScheduler.run(goal,
               reconciler: resume_reconciler,
               supervisor: sup,
               resume_token: token
             )

    assert resumed.collective == :converged
    assert resumed.groups == [{"a", :converged}, {"b", :converged}, {"c", :converged}]

    # The checkpoint is consumed on a successful resume — a stale re-resume of
    # the same token no longer resolves.
    assert PauseCheckpointStore.fetch(token) == :error

    assert {:ok, unpaused} =
             DepScheduler.run(two_frontier_goal(),
               reconciler: fn _group_id -> :converged end,
               supervisor: sup
             )

    assert Enum.sort(resumed.groups) == Enum.sort(unpaused.groups)
    assert resumed.collective == unpaused.collective
  end

  test "resuming against a tampered goal refuses loudly instead of silently continuing", %{
    sup: sup
  } do
    test_pid = self()
    goal = two_frontier_goal()

    pause_task =
      Task.async(fn ->
        DepScheduler.run(goal,
          reconciler: gated_reconciler(test_pid),
          supervisor: sup,
          pause_between_waves: true
        )
      end)

    assert_receive {:dispatched, "a", a_pid}
    assert_receive {:dispatched, "b", b_pid}
    send(a_pid, {:release, "a", :converged})
    send(b_pid, {:release, "b", :converged})

    assert {:ok, %{collective: :paused, resume_token: token}} = Task.await(pause_task)

    tampered_goal =
      Goal.new("multi-frontier",
        groups: [
          Group.new("a", "A"),
          Group.new("b", "B"),
          # a NEW dependency edge -- the goal-set content hash must change.
          Group.new("c", "C", needs: ["a"])
        ]
      )

    assert {:error, {:goal_changed, message}} =
             DepScheduler.run(tampered_goal,
               reconciler: fn _group_id -> :converged end,
               supervisor: sup,
               resume_token: token
             )

    assert message =~ "goal file changed"

    # The refused resume did NOT consume the checkpoint — it is still there for
    # a correct resume (or an operator inspecting what was paused).
    assert {:ok, _checkpoint} = PauseCheckpointStore.fetch(token)
  end

  test "without the flag, behavior is unchanged (the pinned frontier events still fire)", %{
    sup: sup
  } do
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

    assert result.collective == :converged
    assert result.resume_token == nil
    assert_received {:stream_event, %{event: "frontier_complete", frontier: 0}}
    assert_received {:stream_event, %{event: "frontier_complete", frontier: 1}}
  end
end

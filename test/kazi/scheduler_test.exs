defmodule Kazi.SchedulerTest do
  @moduledoc """
  T21.1 acceptance (UC-037, ADR-0027): the parallel coordinator starts one
  supervised reconciler per partition under a `DynamicSupervisor`, runs them
  CONCURRENTLY, collects each terminal status, and reports the correct COLLECTIVE
  verdict (all `converged` ⇒ converged / any `over_budget` ⇒ over_budget /
  otherwise any `stuck` ⇒ stuck).

  Every case is hermetic: the reconciler is an injected STUB (no real harness, no
  loop, no NATS). Each test starts its OWN isolated
  `Kazi.Scheduler.PartitionSupervisor` instance so the cases never contend on the
  application-tree supervisor and can run `async`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kazi.Scheduler
  alias Kazi.Scheduler.PartitionSupervisor

  doctest Kazi.Scheduler

  setup do
    # An isolated DynamicSupervisor instance per test (not the named app-tree one),
    # so concurrent async tests never share the reconciler population.
    {:ok, sup} = start_supervised(PartitionSupervisor)
    %{sup: sup}
  end

  describe "collective_verdict/1 (the pure fold)" do
    test "all converged ⇒ converged" do
      assert Scheduler.collective_verdict([:converged, :converged, :converged]) == :converged
    end

    test "empty list ⇒ converged (vacuous success)" do
      assert Scheduler.collective_verdict([]) == :converged
    end

    test "any over_budget ⇒ over_budget (even alongside converged/stuck)" do
      assert Scheduler.collective_verdict([:converged, :over_budget]) == :over_budget
      assert Scheduler.collective_verdict([:stuck, :over_budget, :converged]) == :over_budget
    end

    test "any stuck/stopped/crashed (no over_budget) ⇒ stuck" do
      assert Scheduler.collective_verdict([:converged, :stuck]) == :stuck
      assert Scheduler.collective_verdict([:converged, :stopped]) == :stuck
      assert Scheduler.collective_verdict([:converged, :crashed]) == :stuck
    end

    test "single status degenerates to its own collective mapping" do
      assert Scheduler.collective_verdict([:converged]) == :converged
      assert Scheduler.collective_verdict([:over_budget]) == :over_budget
      assert Scheduler.collective_verdict([:stuck]) == :stuck
    end
  end

  describe "run/2 collective verdict over N partitions" do
    test "all partitions converged ⇒ collective converged", %{sup: sup} do
      partitions = [:p1, :p2, :p3]
      reconciler = fn _partition -> :converged end

      assert {:ok, result} = Scheduler.run(partitions, reconciler: reconciler, supervisor: sup)
      assert result.collective == :converged
      assert Enum.map(result.partitions, &elem(&1, 1)) == [:converged, :converged, :converged]
    end

    test "any partition stuck ⇒ collective stuck", %{sup: sup} do
      statuses = %{p1: :converged, p2: :stuck, p3: :converged}
      reconciler = fn partition -> Map.fetch!(statuses, partition) end

      assert {:ok, result} =
               Scheduler.run([:p1, :p2, :p3], reconciler: reconciler, supervisor: sup)

      assert result.collective == :stuck
    end

    test "any partition over_budget ⇒ collective over_budget (beats a stuck sibling)", %{sup: sup} do
      statuses = %{p1: :converged, p2: :stuck, p3: :over_budget}
      reconciler = fn partition -> Map.fetch!(statuses, partition) end

      assert {:ok, result} =
               Scheduler.run([:p1, :p2, :p3], reconciler: reconciler, supervisor: sup)

      assert result.collective == :over_budget
    end

    test "each terminal status maps to the right per-partition status in input order", %{sup: sup} do
      statuses = %{a: :converged, b: :stuck, c: :over_budget, d: :stopped}
      reconciler = fn partition -> Map.fetch!(statuses, partition) end

      assert {:ok, result} =
               Scheduler.run([:a, :b, :c, :d], reconciler: reconciler, supervisor: sup)

      assert result.partitions == [
               {:a, :converged},
               {:b, :stuck},
               {:c, :over_budget},
               {:d, :stopped}
             ]

      # over_budget present ⇒ over_budget wins the collective verdict
      assert result.collective == :over_budget
    end

    test "a reconciler returning {:error, _} is recorded stuck (never success)", %{sup: sup} do
      reconciler = fn
        :ok_one -> :converged
        :bad -> {:error, :boom}
      end

      assert {:ok, result} =
               Scheduler.run([:ok_one, :bad], reconciler: reconciler, supervisor: sup)

      assert [{:ok_one, :converged}, {:bad, :stuck}] = result.partitions
      assert result.collective == :stuck
    end

    test "a crashing reconciler is contained as :crashed; the coordinator survives", %{sup: sup} do
      reconciler = fn
        :good -> :converged
        :crash -> raise "kaboom"
      end

      # The crash is logged by the reconciler's task; capture it so the expected
      # failure does not pollute test output.
      result =
        with_log(fn ->
          assert {:ok, result} =
                   Scheduler.run([:good, :crash], reconciler: reconciler, supervisor: sup)

          result
        end)
        |> elem(0)

      assert [{:good, :converged}, {:crash, :crashed}] = result.partitions
      assert result.collective == :stuck
    end
  end

  describe "run/2 degenerate single-partition case (serial parity)" do
    test "a single-partition set returns exactly that partition's status", %{sup: sup} do
      for status <- [:converged, :stuck, :over_budget, :stopped] do
        reconciler = fn :solo -> status end

        assert {:ok, result} = Scheduler.run([:solo], reconciler: reconciler, supervisor: sup)
        assert result.partitions == [{:solo, normalize(status)}]
        assert result.collective == expected_collective(status)
      end
    end

    # The single-partition collective verdict is exactly the serial single-goal
    # outcome: converged stays converged, over_budget stays over_budget, every
    # non-converged terminal collapses to stuck.
    defp expected_collective(:converged), do: :converged
    defp expected_collective(:over_budget), do: :over_budget
    defp expected_collective(_), do: :stuck

    defp normalize(status), do: status
  end

  describe "run/2 runs reconcilers CONCURRENTLY (real overlap, deterministic)" do
    test "N reconcilers that each block until all N have started all complete", %{sup: sup} do
      # Concurrency proof: each reconciler increments a shared counter, then BLOCKS
      # until the counter reaches N. If the coordinator ran the reconcilers
      # serially, the first would block forever waiting for siblings that never
      # start — the run would time out. It completes ONLY because all N run
      # concurrently. Deterministic: the barrier is a precise count, not a sleep.
      n = 4
      partitions = Enum.map(1..n, &{:p, &1})
      counter = start_counter()

      reconciler = fn _partition ->
        arrive(counter)
        await_all(counter, n)
        :converged
      end

      assert {:ok, result} =
               Scheduler.run(partitions,
                 reconciler: reconciler,
                 supervisor: sup,
                 # a finite timeout so a serial regression FAILS the test instead
                 # of hanging it
                 reconcile_timeout: 2_000
               )

      assert result.collective == :converged
      assert length(result.partitions) == n
      assert Enum.all?(result.partitions, fn {_p, s} -> s == :converged end)
    end

    test "a reconciler exceeding its timeout is recorded :stuck", %{sup: sup} do
      reconciler = fn
        :fast -> :converged
        :slow -> Process.sleep(:infinity)
      end

      assert {:ok, result} =
               Scheduler.run([:fast, :slow],
                 reconciler: reconciler,
                 supervisor: sup,
                 reconcile_timeout: 100
               )

      assert [{:fast, :converged}, {:slow, :stuck}] = result.partitions
      assert result.collective == :stuck
    end
  end

  describe "run/2 supervision" do
    test "each partition runs under the DynamicSupervisor", %{sup: sup} do
      # Observe that the reconcilers actually run as children of the injected
      # DynamicSupervisor: at peak, all N are alive under `sup`.
      n = 3
      counter = start_counter()
      test_pid = self()

      reconciler = fn _partition ->
        arrive(counter)
        await_all(counter, n)
        # report the live child count under the supervisor while all are running
        send(test_pid, {:children, DynamicSupervisor.count_children(sup)})
        :converged
      end

      assert {:ok, result} =
               Scheduler.run(Enum.to_list(1..n),
                 reconciler: reconciler,
                 supervisor: sup,
                 reconcile_timeout: 2_000
               )

      assert result.collective == :converged
      # At the barrier, all N reconcilers were active children of `sup`.
      assert_receive {:children, %{active: active}} when active >= n
    end
  end

  # --- a tiny deterministic barrier (a shared counter Agent) ------------------

  defp start_counter do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    agent
  end

  defp arrive(agent), do: Agent.update(agent, &(&1 + 1))

  # Spin (deterministically) until the counter reaches `n` — i.e. all siblings
  # have started. Bounded by the run's reconcile_timeout, so a serial run (where
  # the count never reaches n) fails rather than hangs forever.
  defp await_all(agent, n) do
    if Agent.get(agent, & &1) >= n do
      :ok
    else
      Process.sleep(5)
      await_all(agent, n)
    end
  end
end

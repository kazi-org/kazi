defmodule Kazi.Scheduler.PartitionSupervisorTest do
  @moduledoc """
  T21.12 regression: `PartitionSupervisor.ensure_started/1` guarantees a running
  partition-reconciler supervisor before the CLI `apply --parallel` path dispatches.

  The ship-blocker was `--parallel` exiting 1 with
  `{:noproc, {GenServer, :call, [Kazi.Scheduler.PartitionSupervisor, {:start_child, ...}]}}`
  on the RELEASED (Burrito) binary: the standalone binary hands straight to the CLI
  before the app supervision tree is stood up, so the NAMED supervisor was absent and
  `start_child/2` had nothing to call. `ensure_started/1` is the fix — these cases
  exercise it against a FRESH, not-yet-started name (simulating the standalone path
  the running app tree masks), proving `start_child/2` then works rather than
  crashing with `:noproc`.
  """
  use ExUnit.Case, async: true

  alias Kazi.Scheduler.PartitionSupervisor

  defp fresh_name do
    :"test_partition_sup_#{System.unique_integer([:positive])}"
  end

  test "starts the named supervisor when it is absent (the standalone-binary path)" do
    name = fresh_name()
    refute Process.whereis(name), "precondition: the name must be unregistered"

    assert {:ok, pid} = PartitionSupervisor.ensure_started(name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    assert is_pid(pid)
    assert Process.alive?(pid)
    assert Process.whereis(name) == pid
  end

  test "start_child/2 works after ensure_started — the :noproc crash is gone" do
    name = fresh_name()
    {:ok, pid} = PartitionSupervisor.ensure_started(name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    # The exact call that crashed with :noproc when the supervisor was absent.
    spec = Supervisor.child_spec({Task, fn -> :ok end}, restart: :temporary)
    assert {:ok, child} = PartitionSupervisor.start_child(name, spec)
    assert is_pid(child)
  end

  test "is idempotent — a second call returns the same running pid" do
    name = fresh_name()
    {:ok, pid} = PartitionSupervisor.ensure_started(name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    assert {:ok, ^pid} = PartitionSupervisor.ensure_started(name)
  end

  test "returns the app-tree instance for the default name (mix/release-app path)" do
    # In the running app the default name is already supervised; ensure_started must
    # return that pid, not start a competing instance.
    assert {:ok, pid} = PartitionSupervisor.ensure_started()
    assert Process.whereis(PartitionSupervisor) == pid
  end
end

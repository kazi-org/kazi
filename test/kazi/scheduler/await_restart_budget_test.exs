defmodule Kazi.Scheduler.AwaitRestartBudgetTest do
  @moduledoc """
  M7 (deep-review-001): the coordinator's own `:await` call timeout accounts for
  the restart budget -- `(max_restarts + 1) * reconcile_timeout` -- so a
  partition that crashes and restarts several times cannot make `Scheduler.run/2`
  raise `exit(:timeout)` (crashing the whole run) before the restarting
  partition has had its full worst-case wall time to finish.

  Hermetic: a real crash-then-restart chain (real process kills, real
  `reconcile_timeout`s), sized so the OLD `timeout * 4 + 5_000` formula would
  have fired the coordinator's await BEFORE the chain could finish, while the
  restart-aware formula safely outlives it.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kazi.Scheduler
  alias Kazi.Scheduler.PartitionSupervisor

  setup do
    {:ok, sup} = start_supervised(PartitionSupervisor)
    %{sup: sup}
  end

  test "a long restart chain converges instead of the coordinator's await firing early",
       %{sup: sup} do
    # reconcile_timeout: 1_500, max_restarts: 15 -- worst-case wall time is
    # (15 + 1) * 1_500 = 24_000ms. The OLD `timeout * 4 + 5_000` formula would
    # have capped the coordinator's await at 1_500 * 4 + 5_000 = 11_000ms, well
    # under the ~15_000ms this crash-then-restart chain actually takes (15
    # attempts each sleeping ~1_000ms before crashing, then converging) -- so
    # under the OLD code this run would have raised exit(:timeout) partway
    # through. Under the fix it converges.
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    reconciler = fn :flaky ->
      n = Agent.get_and_update(attempts, fn a -> {a + 1, a + 1} end)

      if n <= 15 do
        # Sleep well under reconcile_timeout so this is a genuine crash+restart,
        # not a wedge that times out to a terminal :stuck.
        Process.sleep(1_000)
        Process.exit(self(), :kill)
      else
        :converged
      end
    end

    capture_log(fn ->
      assert {:ok, %{partitions: [{:flaky, :converged}], collective: :converged}} =
               Scheduler.run([:flaky],
                 reconciler: reconciler,
                 supervisor: sup,
                 max_restarts: 15,
                 reconcile_timeout: 1_500
               )
    end)

    # 15 crashing attempts + 1 converging attempt.
    assert Agent.get(attempts, & &1) == 16
  end
end

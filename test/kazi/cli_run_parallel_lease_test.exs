defmodule Kazi.CLIRunParallelLeaseTest do
  @moduledoc """
  T21.9 wiring: `kazi apply --parallel` engages the partition LEASE layer on the
  PRODUCTION path, so the operator dashboard's lease map (`/leases`,
  `KaziWeb.CoordinationSource.Native`) renders the live native-parallel leases.

  Before this fix the CLI composed the scheduler opts WITHOUT a `:lease` key, so
  `Kazi.Scheduler.run_goals/2` skipped `Kazi.Scheduler.LeasedReconciler.wrap/2`
  entirely and nothing was ever published into the globally-readable
  `Kazi.Coordination.LeaseTable` — the dashboard lease map stayed empty on every
  native run. `run_goal_parallel/4` now injects a default lease (a per-run
  in-memory store published into the `LeaseTable`) whenever the caller has not
  injected its own `:reconciler` or `:lease` seam.

  This is a Tier-2 boundary test: it drives the REAL CLI exec core
  (`Kazi.CLI.run/2`) — NO injected reconciler, NO injected lease — against a
  goal-file that fails at t0 and converges once a stub harness writes the fix. A
  capturing predicate provider reads the live `LeaseTable` AT EVALUATION TIME,
  which happens INSIDE the partition's lease wrapper, so it observes the held
  lease the dashboard would render. The only injected seams are a hermetic graph
  source (no repo-map/network) and the per-goal run opts (the stub harness +
  capturing provider) — neither disables the default lease.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.Coordination.Lease
  alias Kazi.Coordination.LeaseTable
  alias Kazi.Repo

  # A hermetic graph source: maps each partition term to a fixed file list, so
  # partitioning never reads the repo-map or the filesystem.
  defmodule TermSource do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    @impl true
    def survey(_workspace, terms, opts) do
      mapping = Keyword.fetch!(opts, :mapping)

      files =
        terms
        |> Enum.flat_map(&Map.get(mapping, &1, []))
        |> Enum.uniq()
        |> Enum.map(&FileRef.new/1)

      Survey.new(:graph, files: files)
    end

    def new(mapping), do: {__MODULE__, mapping: mapping}
  end

  # A `:custom_script` provider that records the live LeaseTable snapshot to the
  # test (via app env, since the partition reconciles in a spawned process) before
  # delegating to the real provider. Evaluation runs inside the lease wrapper, so a
  # non-empty snapshot proves the CLI engaged the lease layer.
  defmodule LeaseProbeProvider do
    @moduledoc false
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(predicate, context) do
      case Application.get_env(:kazi, :lease_probe_test_pid) do
        pid when is_pid(pid) -> send(pid, {:lease_snapshot, LeaseTable.list()})
        _ -> :ok
      end

      Kazi.Providers.CustomScript.evaluate(predicate, context)
    end
  end

  # Check out the SQL sandbox so the CLI's read-model boot finds an owned
  # connection (shared mode so the spawned partition process can use it too).
  defp checkout_sandbox(_ctx) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  setup :checkout_sandbox

  @tag :tmp_dir
  test "a real --parallel run publishes the partition's lease into the LeaseTable",
       %{tmp_dir: tmp_dir} do
    Application.put_env(:kazi, :lease_probe_test_pid, self())
    on_exit(fn -> Application.delete_env(:kazi, :lease_probe_test_pid) end)

    goal_file = write_parallel_goal_file(tmp_dir)
    harness_stub = write_harness_stub(tmp_dir)

    # NO :reconciler and NO :lease injected — exactly the production path. The graph
    # source + run_opts (stub harness, capturing provider) are the only seams, and
    # neither suppresses the default lease the CLI now injects.
    inject_opts = [
      graph_source: TermSource.new(%{"a" => ["lib/a.ex"]}),
      reconcile_timeout: 30_000,
      run_opts: [
        persist?: false,
        adapter_opts: [command: harness_stub],
        providers: %{custom_script: LeaseProbeProvider},
        reobserve_interval_ms: 5,
        await_timeout: 20_000
      ]
    ]

    out =
      capture_io(fn ->
        assert Kazi.CLI.run(
                 ["apply", goal_file, "--workspace", tmp_dir, "--parallel"],
                 inject_opts
               ) == 0
      end)

    # The real reconcile converged through the CLI parallel path.
    assert out =~ "COLLECTIVE CONVERGED"
    assert File.exists?(Path.join(tmp_dir, "fixed.txt"))

    # The discriminating assertion: at least one evaluation, taken WHILE the
    # partition held its lease, saw a non-empty LeaseTable — i.e. the CLI engaged
    # the lease layer and published into the table the dashboard reads. Pre-fix
    # every snapshot would be empty (no lease was ever recorded).
    snapshots = drain_snapshots([])
    assert snapshots != [], "the capturing provider never ran"

    held = Enum.find(snapshots, fn snap -> snap != [] end)

    assert [%Lease{} = lease | _] = held,
           "no lease was held during reconcile — the CLI did not engage the lease layer"

    # The held lease is the partition's blast-radius lease (a real, readable entry).
    assert is_binary(lease.key) and lease.key != ""
    assert is_binary(lease.holder) and lease.holder != ""
  end

  # Drain every {:lease_snapshot, _} the capturing provider sent this run.
  defp drain_snapshots(acc) do
    receive do
      {:lease_snapshot, snap} -> drain_snapshots([snap | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A goal-file with one partition term `a` (resolved hermetically by the injected
  # graph source) and one `custom_script` predicate that fails at t0 (no fixed.txt)
  # so the goal is non-vacuous and runs the reconcile; the stub harness writes the
  # file so it converges.
  defp write_parallel_goal_file(tmp_dir) do
    path = Path.join(tmp_dir, "parallel_lease_goal.toml")

    File.write!(path, """
    id = "cli-parallel-lease"
    name = "CLI run --parallel engages the lease layer"

    [scope]
    workspace = "#{tmp_dir}"

    [metadata]
    partition_terms = ["a"]

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  # A stub harness that makes the failing predicate pass (writes fixed.txt in the
  # workspace cwd), so the reconcile converges in one iteration.
  defp write_harness_stub(tmp_dir) do
    path = Path.join(tmp_dir, "stub_harness.sh")

    File.write!(path, """
    #!/bin/sh
    echo "the converged fix" > fixed.txt
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end
end

defmodule Kazi.CLISingleNodeTest do
  @moduledoc """
  T73.5 (ADR-0086/ADR-0087): `kazi apply` under single_node mode
  (`--single-node` or `KAZI_SINGLE_NODE=1`/`"true"`) caps the invocation to
  ONE node -- a Sire dispatcher lane runs one goal per container and refuses
  fleet/partition fan-out itself.

  Four capabilities, one file, each driven through the REAL CLI exec core
  (`Kazi.CLI.run/2`), output captured with `ExUnit.CaptureIO`:

    1. `--single-node`/`KAZI_SINGLE_NODE` + `--fleet` refuses BEFORE
       `Kazi.Fleet.load/1` ever runs.
    2. `--single-node` + `--parallel` over a goal-set that would partition
       into MORE THAN ONE partition refuses BEFORE
       `Kazi.Scheduler.run_goals/2` ever dispatches (a spy reconciler proves
       it).
    3. A ONE-partition run under single_node (serial, and single-partition
       `--parallel`) RUNS NORMALLY and its `--json` result carries the
       additive `"single_node": true`.
    4. Negative-space regression guard: with single_node NOT requested,
       `--fleet` and a multi-partition `--parallel` run are COMPLETELY
       UNAFFECTED, and no `--json` result ever carries a `single_node` key.

  HERMETIC: no real git repo, no real harness beyond a tiny shell stub, no
  network -- an injected `:graph_source` and (for the scheduler paths) an
  injected `:reconciler` stand in for the real partitioning/dispatch seams,
  the same seams `cli_run_parallel_json_test.exs` and
  `cli_run_schedule_explain_test.exs` use.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.Repo

  # A hermetic graph source (no repo-map/filesystem scan): each term maps
  # directly to a same-named file, so two DIFFERENTLY-NAMED groups (their
  # fallback terms, absent `partition_terms`) always land in disjoint blast
  # radii -- mirrors `cli_run_parallel_worktree_isolation_test.exs`'s
  # `TermSource`.
  defmodule TermSource do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    @impl true
    def survey(_workspace, terms, _opts) do
      files = terms |> Enum.map(&to_string/1) |> Enum.map(&FileRef.new/1)
      Survey.new(:graph, files: files)
    end
  end

  # Check out the SQL sandbox so the CLI's read-model boot finds an owned
  # connection -- none of these runs depend on persistence (every scheduler
  # path here injects its own reconciler/stub), but this keeps the suite
  # output clean rather than logging a degraded-persistence warning.
  defp checkout_sandbox(_ctx) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  setup :checkout_sandbox
  @moduletag :tmp_dir

  # ===========================================================================
  # CAPABILITY 1/4 -- single_node + --fleet refuses before Kazi.Fleet.load/1
  # ===========================================================================

  describe "apply --fleet under single_node" do
    @describetag :single_node_fleet_refusal

    test "--single-node refuses --fleet before any load, exit 1, JSON reason single_node_violation",
         %{tmp_dir: tmp_dir} do
      fleet_dir = Path.join(tmp_dir, "does-not-exist")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["apply", fleet_dir, "--fleet", "--single-node", "--json"],
                   []
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "single_node_violation"
      assert payload["error"] =~ "--fleet"
      assert payload["error"] =~ fleet_dir
    end

    test "KAZI_SINGLE_NODE=1 is the env-var equivalent of --single-node", %{tmp_dir: tmp_dir} do
      fleet_dir = Path.join(tmp_dir, "does-not-exist")
      System.put_env("KAZI_SINGLE_NODE", "1")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", fleet_dir, "--fleet", "--json"], []) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "single_node_violation"
      assert payload["error"] =~ "--fleet"
    after
      System.delete_env("KAZI_SINGLE_NODE")
    end

    test "human output carries the same refusal, stderr prefixed error:", %{tmp_dir: tmp_dir} do
      fleet_dir = Path.join(tmp_dir, "does-not-exist")

      out =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["apply", fleet_dir, "--fleet", "--single-node"], []) == 1
        end)

      assert out =~ "error:"
      assert out =~ "--fleet"
      assert out =~ fleet_dir
    end
  end

  # ===========================================================================
  # CAPABILITY 2/4 -- single_node + --parallel over >1 partition refuses
  # before Kazi.Scheduler.run_goals/2 ever dispatches
  # ===========================================================================

  describe "apply --parallel under single_node" do
    @describetag :single_node_partition_refusal

    test "refuses a two-partition goal-set before dispatch, naming the count",
         %{tmp_dir: tmp_dir} do
      goal_file = write_two_group_goal_file(tmp_dir)
      {:ok, spy} = Agent.start_link(fn -> [] end)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     tmp_dir,
                     "--parallel",
                     "--single-node",
                     "--json"
                   ],
                   group_spy_inject_opts(spy)
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "single_node_violation"
      assert payload["error"] =~ "2 partitions"

      # The discriminating assertion: the scheduler's group reconciler seam
      # was NEVER invoked -- no partition worktree/lease/harness was created.
      assert Agent.get(spy, & &1) == []
    end
  end

  # ===========================================================================
  # CAPABILITY 3/4 -- a ONE-partition run under single_node runs normally and
  # its --json result carries the additive "single_node": true
  # ===========================================================================

  describe "a one-partition run under single_node" do
    @describetag :single_node_result_field

    test "serial converge carries single_node: true", %{tmp_dir: tmp_dir} do
      goal_file = write_serial_goal_file(tmp_dir)
      harness_stub = write_harness_stub(tmp_dir)

      runtime_opts = [
        adapter_opts: [command: harness_stub],
        reobserve_interval_ms: 5,
        await_timeout: 15_000,
        persist?: false
      ]

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["apply", goal_file, "--workspace", tmp_dir, "--single-node", "--json"],
                   runtime_opts
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "converged"
      assert payload["single_node"] == true
    end

    test "single-partition --parallel carries single_node: true", %{tmp_dir: tmp_dir} do
      goal_file = write_single_partition_goal_file(tmp_dir)
      {:ok, spy} = Agent.start_link(fn -> [] end)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     tmp_dir,
                     "--parallel",
                     "--single-node",
                     "--json"
                   ],
                   spy_inject_opts(spy)
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["collective"] == "converged"
      assert payload["single_node"] == true
      assert length(Agent.get(spy, & &1)) == 1
    end
  end

  # ===========================================================================
  # CAPABILITY 4/4 -- negative-space regression guard: single_node NOT
  # requested leaves --fleet and multi-partition --parallel unaffected, and
  # no --json result ever carries a single_node key
  # ===========================================================================

  describe "without single_node" do
    @describetag :single_node_unset_unchanged

    test "--fleet is unaffected: Kazi.Fleet.load/1 runs and reports its OWN error, not single_node_violation",
         %{tmp_dir: tmp_dir} do
      fleet_dir = Path.join(tmp_dir, "does-not-exist")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["apply", fleet_dir, "--fleet", "--json"], []) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      refute Map.has_key?(payload, "reason")
      assert payload["error"] =~ "fleet path"
      assert payload["error"] =~ "does not exist"
    end

    test "a multi-partition --parallel run proceeds normally, dispatching the reconciler per partition",
         %{tmp_dir: tmp_dir} do
      goal_file = write_two_group_goal_file(tmp_dir)
      {:ok, spy} = Agent.start_link(fn -> [] end)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["apply", goal_file, "--workspace", tmp_dir, "--parallel", "--json"],
                   group_spy_inject_opts(spy)
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["collective"] == "converged"
      refute Map.has_key?(payload, "single_node")
      assert length(Agent.get(spy, & &1)) == 2
    end

    test "a converged single-partition run's JSON has no single_node key", %{tmp_dir: tmp_dir} do
      goal_file = write_single_partition_goal_file(tmp_dir)
      {:ok, spy} = Agent.start_link(fn -> [] end)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["apply", goal_file, "--workspace", tmp_dir, "--parallel", "--json"],
                   spy_inject_opts(spy)
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["collective"] == "converged"
      refute Map.has_key?(payload, "single_node")
    end
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  # The FLAT scheduler seams (`Kazi.Scheduler.run_goals_flat/2`): a static
  # graph source + a SPY reconciler recording each invocation before
  # returning `:converged`. `write_single_partition_goal_file/1` has ONE
  # group, so `Kazi.Scheduler.group_parallel?/1` is false and `run_goals/2`
  # takes this flat path (mirrors `cli_run_parallel_json_test.exs`). No
  # lease/worktree opts -- injecting `:reconciler` makes the scheduler skip
  # both layers, so no real git repo is required.
  defp spy_inject_opts(spy) do
    [
      graph_source: {TermSource, []},
      reconciler: fn _partition, _worktree_path ->
        Agent.update(spy, fn calls -> [:called | calls] end)
        :converged
      end,
      reconcile_timeout: 5_000
    ]
  end

  # The GROUP/DAG scheduler seams (`Kazi.Scheduler.DepScheduler`, via
  # `run_goal_dag/2`): `write_two_group_goal_file/1` has TWO groups with every
  # predicate declaring one, so `group_parallel?/1` is true and `run_goals/2`
  # routes here even though the goal declares NO `needs` edges (both groups
  # land in one fully-parallel frontier) -- mirrors
  # `cli_run_schedule_explain_test.exs`'s `dag_inject_opts`/`spy_inject_opts`.
  # The group reconciler is 1-arity (the group id), NOT the flat scheduler's
  # 2-arity `{partition, worktree_path}`.
  defp group_spy_inject_opts(spy) do
    [
      graph_source: {TermSource, []},
      group_reconciler: fn group_id ->
        Agent.update(spy, fn calls -> [group_id | calls] end)
        :converged
      end,
      reconcile_timeout: 5_000
    ]
  end

  # Two disjoint no-needs groups, no `partition_terms` (falls back to the
  # group id, T21.12) -- one frontier, TWO partitions under the hermetic
  # `TermSource` (distinct group ids -> distinct files -> disjoint radii).
  # Each predicate trivially passes (`cmd sh -c true`): with a real
  # reconciler this run WOULD converge (exercised by capability 4); with
  # single_node ON it is refused before the reconciler is ever called
  # (capability 2).
  defp write_two_group_goal_file(tmp_dir) do
    path = Path.join(tmp_dir, "two_group_goal.toml")

    File.write!(path, """
    id = "cli-single-node-partition"
    name = "CLI single_node multi-partition fixture"

    [scope]
    workspace = "#{tmp_dir}"

    [[group]]
    id = "alpha"
    name = "Alpha"

    [[group]]
    id = "beta"
    name = "Beta"

    [[predicate]]
    id = "alpha-ok"
    provider = "custom_script"
    cmd = "sh"
    args = ["-c", "true"]
    group = "alpha"

    [[predicate]]
    id = "beta-ok"
    provider = "custom_script"
    cmd = "sh"
    args = ["-c", "true"]
    group = "beta"
    """)

    path
  end

  # A single-group goal -- one frontier, ONE partition -- for the
  # single-partition `--parallel` assertions (capability 3's positive case,
  # capability 4's negative-space "no single_node key" case).
  defp write_single_partition_goal_file(tmp_dir) do
    path = Path.join(tmp_dir, "single_partition_goal.toml")

    File.write!(path, """
    id = "cli-single-node-one-partition"
    name = "CLI single_node one-partition fixture"

    [scope]
    workspace = "#{tmp_dir}"

    [[group]]
    id = "solo"
    name = "Solo"

    [[predicate]]
    id = "solo-ok"
    provider = "custom_script"
    cmd = "sh"
    args = ["-c", "true"]
    group = "solo"
    """)

    path
  end

  # A plain (no `[[group]]`) goal for the SERIAL converge assertion: the
  # predicate fails at t0 (no fixed.txt), so the goal is non-vacuous and the
  # loop actually reconciles via the stub harness below. A plain, non-git
  # `tmp_dir` workspace runs the serial loop IN PLACE (no worktree, no
  # `--allow-primary-workspace` needed).
  defp write_serial_goal_file(tmp_dir) do
    path = Path.join(tmp_dir, "serial_goal.toml")

    File.write!(path, """
    id = "cli-single-node-serial"
    name = "CLI single_node serial converge fixture"

    [scope]
    workspace = "#{tmp_dir}"

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  # A stub harness that makes the serial fixture's failing predicate pass
  # (writes fixed.txt in the workspace cwd), so the loop converges in one
  # iteration -- mirrors `cli_run_parallel_worktree_isolation_test.exs`'s
  # `write_harness_stub/1`.
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

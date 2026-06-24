defmodule Kazi.CLIRunScheduleExplainTest do
  @moduledoc """
  T23.6 (ADR-0028 + ADR-0023): the CLI schedule-reporting + `--explain` dry-run.

  Two surfaces, both driven through the REAL CLI exec core (`Kazi.CLI.run/2`)
  against a goal-file on disk, with the scheduler's injectable seams pointed at
  hermetic stubs (an injected graph source + an injected GROUP reconciler), output
  captured with `ExUnit.CaptureIO`:

    1. **schedule reporting** — `run --parallel --json` over a goal whose groups
       form a `needs`-DAG reports, per group, the TOPOLOGICAL ORDER (which frontier
       each group ran in) + its convergence STATE, and the BLOCKED sub-DAG (the
       blocking dep + blocked dependents) when present.

    2. **`--explain` / `--dry-run`** — `kazi run <goal> --explain` PRINTS the
       computed wave SCHEDULE (the topological frontiers + the blast-radius
       parallelism within each) and dispatches NOTHING — asserted by a SPY group
       reconciler that records into an Agent and must never be invoked. Exit 0;
       non-TTY safe; `--json` emits the schedule as JSON.

  A goal with NO `needs` shows a SINGLE frontier (everything parallel); a chain
  shows N frontiers.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.Repo

  # A hermetic graph source: maps each partition term to a fixed file list, so the
  # blast-radius partitioning never reads the repo-map or the filesystem.
  defmodule TermSource do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    @impl true
    def survey(_workspace, terms, opts) do
      mapping = Keyword.get(opts, :mapping, %{})

      files =
        terms
        |> Enum.flat_map(&Map.get(mapping, &1, []))
        |> Enum.uniq()
        |> Enum.map(&FileRef.new/1)

      Survey.new(:graph, files: files)
    end

    def new(mapping), do: {__MODULE__, mapping: mapping}
  end

  # Check out the SQL sandbox so the CLI's read-model boot finds an owned
  # connection (the run does not depend on persistence — the injected reconciler
  # decides the verdict — but this keeps the suite output clean).
  defp checkout_sandbox(_ctx) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # Tier 1 — `--explain` / `--dry-run` argv boundary
  # ===========================================================================

  describe "parse/1 — run --explain / --dry-run" do
    test "--explain carries through to opts" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["run", "goal.toml", "--workspace", "/tmp/ws", "--explain"])

      assert opts[:explain] == true
    end

    test "--dry-run is an alias of --explain" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["run", "goal.toml", "--workspace", "/tmp/ws", "--dry-run"])

      assert opts[:explain] == true
    end

    test "without --explain/--dry-run the flag defaults to false" do
      assert {:run, "goal.toml", opts} =
               Kazi.CLI.parse(["run", "goal.toml", "--workspace", "/tmp/ws"])

      assert opts[:explain] == false
    end
  end

  # ===========================================================================
  # Tier 2 — run --parallel --json: the per-group SCHEDULE in the collective
  # ===========================================================================

  describe "run --parallel --json — schedule reporting (DAG converged)" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "reports the topological frontier order + per-group state, exit 0",
         %{tmp_dir: tmp_dir} do
      goal_file = write_chain_goal_file(tmp_dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["run", goal_file, "--workspace", tmp_dir, "--parallel", "--json"],
                   converging_dag_inject_opts()
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["schema_version"] == 1
      assert payload["collective"] == "converged"
      assert payload["next_action"] == "done"

      # The schedule is the topological frontiers: a chain a -> b -> c is THREE
      # frontiers, one group each, in order.
      schedule = payload["schedule"]
      assert is_list(schedule)
      assert length(schedule) == 3

      assert [f0, f1, f2] = schedule
      assert f0["frontier"] == 0
      assert group_ids(f0) == ["a"]
      assert group_ids(f1) == ["b"]
      assert group_ids(f2) == ["c"]

      # Each group converged.
      assert Enum.all?(schedule, fn f ->
               Enum.all?(f["groups"], &(&1["state"] == "converged"))
             end)

      # No blocked sub-DAG on a clean converge.
      assert payload["blocked"] == []
    end
  end

  describe "run --parallel --json — a goal with NO needs is one frontier" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "every group is in a single parallel frontier", %{tmp_dir: tmp_dir} do
      goal_file = write_fan_goal_file(tmp_dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["run", goal_file, "--workspace", tmp_dir, "--parallel", "--json"],
                   converging_dag_inject_opts()
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))

      # b and c both `needs` a, so the shape is: frontier 0 = [a]; frontier 1 =
      # [b, c] (both ready the moment a converges — the parallel fan-out).
      assert [f0, f1] = payload["schedule"]
      assert group_ids(f0) == ["a"]
      assert group_ids(f1) == ["b", "c"]
    end
  end

  describe "run --parallel --json — BLOCKED sub-DAG is reported" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "a stuck dep names the blocking dep + its blocked dependents",
         %{tmp_dir: tmp_dir} do
      goal_file = write_chain_goal_file(tmp_dir)

      # `a` goes stuck → `b` (needs a) and `c` (needs b) can never run: both blocked.
      inject =
        dag_inject_opts(fn
          "a" -> :stuck
          _ -> :converged
        end)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["run", goal_file, "--workspace", tmp_dir, "--parallel", "--json"],
                   inject
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["collective"] == "stuck"
      assert payload["next_action"] == "investigate"

      blocked = payload["blocked"]
      blocked_by = Map.new(blocked, fn b -> {b["group"], b["blocked_by"]} end)

      assert blocked_by["b"] == "a"
      assert blocked_by["c"] == "a" or blocked_by["c"] == "b"

      # a's own frontier-0 state is stuck, not blocked.
      [f0 | _] = payload["schedule"]
      assert [%{"group" => "a", "state" => "stuck"}] = f0["groups"]
    end
  end

  describe "run --parallel (human) — schedule block" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "without --json a human schedule block is printed (frontiers + groups)",
         %{tmp_dir: tmp_dir} do
      goal_file = write_chain_goal_file(tmp_dir)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["run", goal_file, "--workspace", tmp_dir, "--parallel"],
                   converging_dag_inject_opts()
                 ) == 0
        end)

      assert out =~ "COLLECTIVE CONVERGED"
      assert out =~ "frontiers: 3"
      assert out =~ "frontier 0: a(converged)"
      assert {:error, %Jason.DecodeError{}} = Jason.decode(String.trim(out))
    end
  end

  # ===========================================================================
  # Tier 2 — run --explain: print the schedule, dispatch NOTHING
  # ===========================================================================

  describe "run --explain — dry-run dispatches nothing" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "prints the frontier order + parallelism and never invokes the reconciler",
         %{tmp_dir: tmp_dir} do
      goal_file = write_chain_goal_file(tmp_dir)
      {:ok, spy} = Agent.start_link(fn -> [] end)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["run", goal_file, "--workspace", tmp_dir, "--explain"],
                   spy_inject_opts(spy)
                 ) == 0
        end)

      # A chain a -> b -> c is THREE frontiers, printed in order.
      assert out =~ "SCHEDULE (dry-run, nothing dispatched)"
      assert out =~ "frontiers: 3"
      assert out =~ "frontier 0: a"
      assert out =~ "frontier 1: b"
      assert out =~ "frontier 2: c"
      assert out =~ "parallelism:"

      # The spy reconciler was NEVER called — nothing was dispatched.
      assert Agent.get(spy, & &1) == []
    end

    test "a goal with NO needs prints a SINGLE frontier (everything parallel)",
         %{tmp_dir: tmp_dir} do
      goal_file = write_no_needs_goal_file(tmp_dir)
      {:ok, spy} = Agent.start_link(fn -> [] end)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["run", goal_file, "--workspace", tmp_dir, "--explain"],
                   spy_inject_opts(spy)
                 ) == 0
        end)

      assert out =~ "frontiers: 1"
      assert Agent.get(spy, & &1) == []
    end

    test "--dry-run behaves identically to --explain", %{tmp_dir: tmp_dir} do
      goal_file = write_chain_goal_file(tmp_dir)
      {:ok, spy} = Agent.start_link(fn -> [] end)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["run", goal_file, "--workspace", tmp_dir, "--dry-run"],
                   spy_inject_opts(spy)
                 ) == 0
        end)

      assert out =~ "frontiers: 3"
      assert Agent.get(spy, & &1) == []
    end
  end

  describe "run --explain --json — schedule as JSON, nothing dispatched" do
    setup :checkout_sandbox
    @describetag :tmp_dir

    test "emits a single JSON schedule object with dispatched=false, exit 0",
         %{tmp_dir: tmp_dir} do
      goal_file = write_chain_goal_file(tmp_dir)
      {:ok, spy} = Agent.start_link(fn -> [] end)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["run", goal_file, "--workspace", tmp_dir, "--explain", "--json"],
                   spy_inject_opts(spy)
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      refute out =~ "SCHEDULE (dry-run"

      assert payload["schema_version"] == 1
      assert payload["mode"] == "explain"
      assert payload["dispatched"] == false
      assert payload["next_action"] == "schedule"

      assert [f0, f1, f2] = payload["frontiers"]
      assert f0["groups"] == ["a"]
      assert f1["groups"] == ["b"]
      assert f2["groups"] == ["c"]

      # Each frontier reports its blast-radius partitions (the parallelism).
      assert is_list(f0["partitions"])
      assert length(f0["partitions"]) >= 1

      assert Agent.get(spy, & &1) == []
    end

    test "a chain shows N frontiers; a fan shows the parallel frontier",
         %{tmp_dir: tmp_dir} do
      goal_file = write_fan_goal_file(tmp_dir)
      {:ok, spy} = Agent.start_link(fn -> [] end)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   ["run", goal_file, "--workspace", tmp_dir, "--explain", "--json"],
                   spy_inject_opts(spy)
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert [f0, f1] = payload["frontiers"]
      assert f0["groups"] == ["a"]
      assert f1["groups"] == ["b", "c"]
      assert Agent.get(spy, & &1) == []
    end
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

  defp group_ids(frontier), do: Enum.map(frontier["groups"], & &1["group"])

  # The DAG scheduler seams: a static graph source + a GROUP reconciler returning a
  # chosen terminal status per group id. No lease/worktree opts ⇒ the scheduler
  # skips both layers.
  defp dag_inject_opts(reconcile_fun) do
    [
      graph_source: TermSource.new(%{}),
      group_reconciler: reconcile_fun,
      reconcile_timeout: 5_000
    ]
  end

  defp converging_dag_inject_opts, do: dag_inject_opts(fn _group -> :converged end)

  # The --explain seams: a SPY group reconciler that records every call so the test
  # can prove it was never invoked (a dry-run dispatches nothing). The graph source
  # is still injected so the in-frontier partitioning stays hermetic.
  defp spy_inject_opts(spy) do
    [
      graph_source: TermSource.new(%{}),
      group_reconciler: fn group_id ->
        Agent.update(spy, fn calls -> [group_id | calls] end)
        :converged
      end,
      reconcile_timeout: 5_000
    ]
  end

  # A goal whose groups a -> b -> c form a CHAIN (b needs a, c needs b): three
  # topological frontiers. Each group carries one predicate referencing it.
  defp write_chain_goal_file(tmp_dir) do
    write_goal_file(tmp_dir, "chain", """
    [[group]]
    id = "a"
    name = "A"

    [[group]]
    id = "b"
    name = "B"
    needs = ["a"]

    [[group]]
    id = "c"
    name = "C"
    needs = ["b"]

    [[predicate]]
    id = "pa"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f never_a.txt"]
    group = "a"

    [[predicate]]
    id = "pb"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f never_b.txt"]
    group = "b"

    [[predicate]]
    id = "pc"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f never_c.txt"]
    group = "c"
    """)
  end

  # A goal whose groups FAN OUT: b and c both `needs` a. Two frontiers: [a] then
  # [b, c] (the parallel wave).
  defp write_fan_goal_file(tmp_dir) do
    write_goal_file(tmp_dir, "fan", """
    [[group]]
    id = "a"
    name = "A"

    [[group]]
    id = "b"
    name = "B"
    needs = ["a"]

    [[group]]
    id = "c"
    name = "C"
    needs = ["a"]

    [[predicate]]
    id = "pa"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f never_a.txt"]
    group = "a"

    [[predicate]]
    id = "pb"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f never_b.txt"]
    group = "b"

    [[predicate]]
    id = "pc"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f never_c.txt"]
    group = "c"
    """)
  end

  # A goal with groups but NO `needs` edges: a single fully-parallel frontier. Note
  # this is NOT a DAG (no needs), so `run --parallel` takes the flat path — but
  # `--explain` still layers it into ONE frontier of all groups.
  defp write_no_needs_goal_file(tmp_dir) do
    write_goal_file(tmp_dir, "no_needs", """
    [[group]]
    id = "a"
    name = "A"

    [[group]]
    id = "b"
    name = "B"

    [[predicate]]
    id = "pa"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f never_a.txt"]
    group = "a"

    [[predicate]]
    id = "pb"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f never_b.txt"]
    group = "b"
    """)
  end

  defp write_goal_file(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "#{name}_goal.toml")

    File.write!(path, """
    id = "cli-#{name}"
    name = "CLI #{name} schedule"

    [scope]
    workspace = "#{tmp_dir}"

    #{body}
    """)

    path
  end
end

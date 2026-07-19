defmodule Kazi.Fleet.DiscoveryTest do
  @moduledoc """
  T50.4 (ADR-0065 decision 3): `kazi apply --fleet <dir>` loads a directory of
  goal-files into a fleet DAG (explicit `[metadata] depends_on` edges + inferred
  scope-overlap serialization), with load-time errors naming the offending
  file(s) and `--explain --json` rendering the schedule without dispatching.

  Pure fixtures under the test tmp dir — no harness, no execution.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kazi.CLI
  alias Kazi.Fleet

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-fleet-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write_goal(dir, filename, id, extra \\ "") do
    contents = """
    id = "#{id}"

    [[predicate]]
    id = "p"
    provider = "custom_script"
    cmd = "true"
    #{extra}
    """

    File.write!(Path.join(dir, filename), contents)
  end

  test "explain --json: A,B independent; C depends_on A; D,E overlap by scope", %{dir: dir} do
    write_goal(dir, "0001-a.goal.toml", "a")
    write_goal(dir, "0002-b.goal.toml", "b")

    write_goal(dir, "0003-c.goal.toml", "c", """
    [metadata]
    depends_on = ["a"]
    """)

    write_goal(dir, "0004-d.goal.toml", "d", """
    [scope]
    paths = ["lib/kazi/"]
    """)

    write_goal(dir, "0005-e.goal.toml", "e", """
    [scope]
    paths = ["lib/"]
    """)

    argv = ["apply", dir, "--fleet", "--explain", "--json"]

    output =
      capture_io(fn ->
        assert CLI.run(argv) == 0
      end)

    payload = Jason.decode!(output)

    assert payload["mode"] == "fleet_explain"
    assert payload["dispatched"] == false

    node_ids = payload["nodes"] |> Enum.map(& &1["id"]) |> Enum.sort()
    assert node_ids == ["a", "b", "c", "d", "e"]

    edges = payload["edges"]
    assert Enum.any?(edges, &(&1["from"] == "a" and &1["to"] == "c" and &1["kind"] == "explicit"))

    assert Enum.any?(
             edges,
             &(&1["from"] == "d" and &1["to"] == "e" and &1["kind"] == "inferred_overlap")
           )

    assert [
             ["a", "b", "d"],
             ["c", "e"]
           ] == Enum.map(payload["frontiers"], &Enum.sort/1)
  end

  test "load-time error: an explicit-edge cycle names both files", %{dir: dir} do
    write_goal(dir, "0001-x.goal.toml", "x", """
    [metadata]
    depends_on = ["y"]
    """)

    write_goal(dir, "0002-y.goal.toml", "y", """
    [metadata]
    depends_on = ["x"]
    """)

    assert {:error, message} = Fleet.load(dir)
    assert message =~ "cycle"
    assert message =~ "0001-x.goal.toml"
    assert message =~ "0002-y.goal.toml"
  end

  test "load-time error: a dangling depends_on names the file and the declared ids", %{dir: dir} do
    write_goal(dir, "0001-a.goal.toml", "a")

    write_goal(dir, "0002-c.goal.toml", "c", """
    [metadata]
    depends_on = ["unknown-goal"]
    """)

    assert {:error, message} = Fleet.load(dir)
    assert message =~ "0002-c.goal.toml"
    assert message =~ "unknown-goal"
    assert message =~ "declared"
  end

  test "load-time error: a duplicate goal id across two files names both", %{dir: dir} do
    write_goal(dir, "0001-a.goal.toml", "dup")
    write_goal(dir, "0002-b.goal.toml", "dup")

    assert {:error, message} = Fleet.load(dir)
    assert message =~ "duplicate goal id"
    assert message =~ "0001-a.goal.toml"
    assert message =~ "0002-b.goal.toml"
  end

  test "goals with no scope paths get no inferred edges", %{dir: dir} do
    write_goal(dir, "0001-a.goal.toml", "a")
    write_goal(dir, "0002-b.goal.toml", "b")

    assert {:ok, %Fleet{edges: []}} = Fleet.load(dir)
  end

  # T50.5 replaced the staged not-yet-implemented refusal: --fleet without
  # --explain now EXECUTES (test/kazi/fleet/execution_test.exs). The execute
  # path's load-time errors still surface loudly before anything dispatches.
  test "executing --fleet against a missing path fails loudly at load", %{dir: dir} do
    argv = ["apply", Path.join(dir, "no-such-fleet"), "--fleet", "--json"]

    {exit_code, output} =
      with_io_and_exit(fn -> CLI.run(argv) end)

    assert exit_code == 1
    payload = Jason.decode!(output)
    assert payload["error"] =~ "does not exist"
  end

  test "--fleet + --in-place is rejected before anything executes", %{dir: dir} do
    write_goal(dir, "0001-a.goal.toml", "a")

    argv = ["apply", dir, "--fleet", "--in-place", "--json"]

    {exit_code, output} =
      with_io_and_exit(fn -> CLI.run(argv) end)

    assert exit_code == 1
    payload = Jason.decode!(output)
    assert payload["error"] =~ "contradictory"
  end

  defp with_io_and_exit(fun) do
    ref = make_ref()

    output =
      capture_io(fn ->
        result = fun.()
        send(self(), {ref, result})
      end)

    receive do
      {^ref, result} -> {result, output}
    after
      0 -> flunk("expected a result to be sent")
    end
  end
end

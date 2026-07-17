defmodule Kazi.Goal.RoadmapApplyTest do
  @moduledoc """
  T45.4 (UC-059, ADR-0075): `kazi apply <roadmap>` runs the roadmap's WHOLE GOALS
  in topological `needs` order via `Kazi.Fleet.Execution` (the goal-level scheduler
  one level up), emitting a roadmap-level collective. Pinned contract:

    1. a 3-goal DIAMOND roadmap runs goals in topological order (recorded via an
       injected member-runner seam);
    2. the collective JSON carries per-goal verdicts + a roadmap-level verdict;
    3. `--explain` exits 0 with the goal-frontier schedule and dispatches NOTHING;
    4. a SINGLE-goal roadmap degrades to plain `kazi apply` (byte-identical).

  Hermetic: the injected `:member_runner` seam returns member verdicts directly, so
  no harness, no worktree, no network.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.CLI
  alias Kazi.Fleet
  alias Kazi.Goal.Roadmap
  alias Kazi.Repo
  alias Kazi.Scheduler.PartitionSupervisor

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

    start_supervised!(PartitionSupervisor)
    :ok
  end

  # --- to_fleet projection (Tier 1, pure) -----------------------------------

  test "to_fleet projects nodes + needs edges onto a Kazi.Fleet" do
    {:ok, roadmap} =
      Roadmap.from_map(%{
        "goals" => [
          inline_entry("a"),
          inline_entry("b", ["a"]),
          inline_entry("c", ["b"])
        ]
      })

    assert %Fleet{nodes: nodes, edges: edges} = Roadmap.to_fleet(roadmap)
    assert Enum.map(nodes, & &1.id) == ["a", "b", "c"]
    assert Enum.all?(nodes, &match?(%Fleet.Node{}, &1))
    assert MapSet.new(edges, &{&1.from, &1.to}) == MapSet.new([{"a", "b"}, {"b", "c"}])
    assert Enum.all?(edges, &(&1.kind == :explicit))
  end

  # --- 1. topological order over a diamond ----------------------------------

  test "a 3-goal diamond runs goals in topological order", %{tmp_dir: tmp_dir} do
    path = write_diamond_roadmap(tmp_dir)
    {:ok, order} = Agent.start_link(fn -> [] end)

    runner = fn %Fleet.Node{id: id} ->
      Agent.update(order, &[id | &1])
      %{status: :converged}
    end

    {out, code} =
      run_cli(["apply", path, "--workspace", tmp_dir, "--json"],
        member_runner: runner,
        fleet_concurrency: 1
      )

    assert code == 0
    assert Jason.decode!(out)["collective"] == "converged"

    seq = order |> Agent.get(& &1) |> Enum.reverse()
    # A first, D last, {B, C} strictly between — the topological invariant of the
    # A -> {B, C} -> D diamond (B/C order within their frontier is not pinned).
    assert List.first(seq) == "a"
    assert List.last(seq) == "d"
    assert Enum.sort(Enum.slice(seq, 1..2)) == ["b", "c"]
  end

  # --- 2. collective JSON: per-goal verdicts + roadmap verdict ---------------

  test "the collective JSON carries per-goal verdicts and a roadmap-level verdict", %{
    tmp_dir: tmp_dir
  } do
    path = write_diamond_roadmap(tmp_dir)

    {out, code} =
      run_cli(["apply", path, "--workspace", tmp_dir, "--json"],
        member_runner: fn _node -> %{status: :converged} end
      )

    assert code == 0
    payload = Jason.decode!(out)

    assert payload["mode"] == "roadmap"
    assert payload["roadmap"] == path
    assert payload["schema_version"] == 2
    # roadmap-level verdict
    assert payload["collective"] == "converged"

    # per-goal verdicts
    goals = payload["goals"]
    assert Enum.map(goals, & &1["id"]) |> Enum.sort() == ["a", "b", "c", "d"]
    assert Enum.all?(goals, &(&1["status"] == "converged"))

    # the goal-frontier schedule is present (A | B,C | D)
    assert is_list(payload["schedule"])
    assert %{"members_total" => 4} = payload["economy"]
  end

  test "a stuck goal makes the roadmap collective non-converged and exits non-zero", %{
    tmp_dir: tmp_dir
  } do
    path = write_diamond_roadmap(tmp_dir)

    runner = fn %Fleet.Node{id: id} ->
      if id == "b", do: %{status: :stuck}, else: %{status: :converged}
    end

    {out, code} =
      run_cli(["apply", path, "--workspace", tmp_dir, "--json"], member_runner: runner)

    assert code == 1
    payload = Jason.decode!(out)
    refute payload["collective"] == "converged"
    b = Enum.find(payload["goals"], &(&1["id"] == "b"))
    assert b["status"] == "stuck"
  end

  # --- 3. --explain dispatches nothing ---------------------------------------

  test "--explain prints the goal-frontier schedule and dispatches nothing", %{tmp_dir: tmp_dir} do
    path = write_diamond_roadmap(tmp_dir)
    test_pid = self()

    spy_runner = fn %Fleet.Node{id: id} ->
      send(test_pid, {:dispatched, id})
      %{status: :converged}
    end

    {out, code} =
      run_cli(["apply", path, "--workspace", tmp_dir, "--explain", "--json"],
        member_runner: spy_runner
      )

    assert code == 0
    payload = Jason.decode!(out)
    assert payload["mode"] == "roadmap_explain"
    assert payload["dispatched"] == false
    assert payload["frontiers"] == [["a"], ["b", "c"], ["d"]]
    assert Enum.map(payload["goals"], & &1["id"]) == ["a", "b", "c", "d"]

    # NOTHING was dispatched.
    refute_receive {:dispatched, _}, 100
  end

  # --- 4. single-goal roadmap degrades to plain apply (byte-identical) -------

  test "a single-goal roadmap is byte-identical to plain apply on that goal", %{tmp_dir: tmp_dir} do
    goal_path = Path.join(tmp_dir, "solo.goal.toml")
    File.write!(goal_path, goal_toml("solo"))

    roadmap_path = Path.join(tmp_dir, "solo.roadmap.toml")

    File.write!(roadmap_path, """
    [[goals]]
    id = "solo"
    path = "solo.goal.toml"
    """)

    # --explain is pure planning (no dispatch, no harness) → deterministic output
    # to compare byte-for-byte.
    {plain_out, plain_code} =
      run_cli(["apply", goal_path, "--workspace", tmp_dir, "--explain", "--json"], [])

    {roadmap_out, roadmap_code} =
      run_cli(["apply", roadmap_path, "--workspace", tmp_dir, "--explain", "--json"], [])

    assert plain_code == roadmap_code
    assert roadmap_out == plain_out
    # sanity: it really is the plain single-goal shape, not a roadmap collective
    refute Jason.decode!(roadmap_out)["mode"] == "roadmap_explain"
  end

  # === fixtures + helpers ====================================================

  # A -> {B, C} -> D, as a roadmap of path members (each a minimal valid goal).
  defp write_diamond_roadmap(tmp_dir) do
    dir = Path.join(tmp_dir, "diamond-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for id <- ~w(a b c d), do: File.write!(Path.join(dir, "#{id}.goal.toml"), goal_toml(id))

    path = Path.join(dir, "pipeline.roadmap.toml")

    File.write!(path, """
    [[goals]]
    id = "a"
    path = "a.goal.toml"

    [[goals]]
    id = "b"
    path = "b.goal.toml"
    needs = ["a"]

    [[goals]]
    id = "c"
    path = "c.goal.toml"
    needs = ["a"]

    [[goals]]
    id = "d"
    path = "d.goal.toml"
    needs = ["b", "c"]
    """)

    path
  end

  defp goal_toml(id) do
    """
    id = "#{id}"
    name = "goal #{id}"

    [[predicate]]
    id = "p"
    provider = "custom_script"
    cmd = "true"
    """
  end

  defp inline_entry(id, needs \\ []) do
    entry = %{
      "id" => id,
      "goal" => %{
        "id" => "#{id}-goal",
        "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
      }
    }

    if needs == [], do: entry, else: Map.put(entry, "needs", needs)
  end

  defp run_cli(argv, runtime_opts) do
    ref = make_ref()
    me = self()
    out = capture_io(fn -> send(me, {ref, CLI.run(argv, runtime_opts)}) end)

    receive do
      {^ref, code} -> {out, code}
    after
      0 -> flunk("expected an exit code")
    end
  end
end

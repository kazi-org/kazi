defmodule Kazi.Fleet.SharedPathsOverlapTest do
  @moduledoc """
  T73.2 (ADR-0087 decision 4): `Kazi.Fleet.load/1` excludes the fleet's
  effective `shared_paths` (T73.1) from BOTH sides of the inferred-overlap
  test before it runs, so two members that overlap ONLY on a declared hotspot
  get no `:inferred_overlap` edge, while a genuinely shared, un-declared path
  still produces one — and that edge carries any hotspots both endpoints also
  touch as `:lease_keys` (T73.3/T73.4 data, not consumed here).

  Pure fixtures under the test tmp dir — no harness, no execution.
  """
  use ExUnit.Case, async: true

  alias Kazi.Fleet
  alias Kazi.Fleet.Edge

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kazi-fleet-shared-overlap-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write_goal(dir, filename, id, extra) do
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

  test "a shared hotspot is excluded from the overlap test but a genuinely shared path still edges",
       %{dir: dir} do
    write_goal(dir, "0001-a.goal.toml", "a", """
    [scope]
    paths = ["mix.exs", "lib/shared/"]
    shared_paths = ["mix.exs"]
    """)

    write_goal(dir, "0002-b.goal.toml", "b", """
    [scope]
    paths = ["mix.exs", "lib/shared/"]
    """)

    assert {:ok, %Fleet{edges: [edge]}} = Fleet.load(dir)

    assert %Edge{from: "a", to: "b", kind: :inferred_overlap} = edge
    # The mix.exs overlap is excluded from the overlap test -> not reported as
    # an overlapping pair, even though both goals declare it as a scope root.
    assert edge.overlap == [{"lib/shared/", "lib/shared/"}]
    # ...but it travels as lease_keys on the edge that still forms for the
    # genuinely shared lib/ path (T73.3/T73.4 will consume this later).
    assert edge.lease_keys == ["mix.exs"]
  end

  test "two goals overlapping ONLY on a shared hotspot get no inferred_overlap edge", %{dir: dir} do
    write_goal(dir, "0001-a.goal.toml", "a", """
    [scope]
    paths = ["mix.exs", "lib/a_only/"]
    shared_paths = ["mix.exs"]
    """)

    write_goal(dir, "0002-b.goal.toml", "b", """
    [scope]
    paths = ["mix.exs", "lib/b_only/"]
    """)

    assert {:ok, %Fleet{edges: []}} = Fleet.load(dir)
  end

  test "a fleet-manifest-level shared_paths declaration excludes it fleet-wide too", %{dir: dir} do
    write_goal(dir, "0001-a.goal.toml", "a", """
    [scope]
    paths = ["docs/plan.md", "lib/shared/"]
    """)

    write_goal(dir, "0002-b.goal.toml", "b", """
    [scope]
    paths = ["docs/plan.md", "lib/shared/"]
    """)

    manifest = """
    shared_paths = ["docs/plan.md"]

    [[member]]
    path = "0001-a.goal.toml"

    [[member]]
    path = "0002-b.goal.toml"
    """

    manifest_path = Path.join(dir, "fleet.toml")
    File.write!(manifest_path, manifest)

    assert {:ok, %Fleet{edges: [edge]}} = Fleet.load(manifest_path)
    assert edge.overlap == [{"lib/shared/", "lib/shared/"}]
    assert edge.lease_keys == ["docs/plan.md"]
  end

  test "no shared_paths declared anywhere keeps today's overlap edges byte-identical", %{dir: dir} do
    write_goal(dir, "0001-d.goal.toml", "d", """
    [scope]
    paths = ["lib/kazi/"]
    """)

    write_goal(dir, "0002-e.goal.toml", "e", """
    [scope]
    paths = ["lib/"]
    """)

    assert {:ok, %Fleet{edges: [edge]}} = Fleet.load(dir)
    assert %Edge{from: "d", to: "e", kind: :inferred_overlap, lease_keys: []} = edge
  end
end

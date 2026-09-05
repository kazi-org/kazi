defmodule Kazi.Fleet.SharedPathsTest do
  @moduledoc """
  T73.1 (ADR-0087 decision 4): `Kazi.Fleet.effective_shared_paths/1` — the
  union of every fleet member goal's own declared `[scope].shared_paths` plus
  an optional fleet-manifest-level `shared_paths` list. Pure fixtures under the
  test tmp dir — no harness, no execution, no partition/overlap exclusion
  (T73.2 consumes this set; it is not built here).
  """
  use ExUnit.Case, async: true

  alias Kazi.Fleet

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-fleet-shared-#{System.unique_integer([:positive])}")
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

  test "a directory fleet's effective set is the union of members' own shared_paths", %{
    dir: dir
  } do
    write_goal(dir, "0001-a.goal.toml", "a", """
    [scope]
    shared_paths = ["mix.exs"]
    """)

    write_goal(dir, "0002-b.goal.toml", "b")

    assert {:ok, fleet} = Fleet.load(dir)
    assert Fleet.effective_shared_paths(fleet) == ["mix.exs"]
  end

  test "a directory fleet with no member declaring shared_paths has an empty effective set", %{
    dir: dir
  } do
    write_goal(dir, "0001-a.goal.toml", "a")
    write_goal(dir, "0002-b.goal.toml", "b")

    assert {:ok, fleet} = Fleet.load(dir)
    assert Fleet.effective_shared_paths(fleet) == []
  end

  test "members' declarations union and de-duplicate across files", %{dir: dir} do
    write_goal(dir, "0001-a.goal.toml", "a", """
    [scope]
    shared_paths = ["mix.exs", "go.mod"]
    """)

    write_goal(dir, "0002-b.goal.toml", "b", """
    [scope]
    shared_paths = ["go.mod"]
    """)

    assert {:ok, fleet} = Fleet.load(dir)
    assert Fleet.effective_shared_paths(fleet) == ["go.mod", "mix.exs"]
  end

  test "a fleet-manifest-level shared_paths declaration unions into the effective set", %{
    dir: dir
  } do
    write_goal(dir, "0001-a.goal.toml", "a")
    write_goal(dir, "0002-b.goal.toml", "b")

    manifest = """
    shared_paths = ["docs/plan.md"]

    [[member]]
    path = "0001-a.goal.toml"

    [[member]]
    path = "0002-b.goal.toml"
    """

    manifest_path = Path.join(dir, "fleet.toml")
    File.write!(manifest_path, manifest)

    assert {:ok, fleet} = Fleet.load(manifest_path)
    assert Fleet.effective_shared_paths(fleet) == ["docs/plan.md"]
  end

  test "manifest-level and member-declared shared_paths union together", %{dir: dir} do
    write_goal(dir, "0001-a.goal.toml", "a", """
    [scope]
    shared_paths = ["mix.exs"]
    """)

    write_goal(dir, "0002-b.goal.toml", "b")

    manifest = """
    shared_paths = ["docs/plan.md"]

    [[member]]
    path = "0001-a.goal.toml"

    [[member]]
    path = "0002-b.goal.toml"
    """

    manifest_path = Path.join(dir, "fleet.toml")
    File.write!(manifest_path, manifest)

    assert {:ok, fleet} = Fleet.load(manifest_path)
    assert Fleet.effective_shared_paths(fleet) == ["docs/plan.md", "mix.exs"]
  end

  test "a manifest declaring no shared_paths contributes none", %{dir: dir} do
    write_goal(dir, "0001-a.goal.toml", "a")

    manifest = """
    [[member]]
    path = "0001-a.goal.toml"
    """

    manifest_path = Path.join(dir, "fleet.toml")
    File.write!(manifest_path, manifest)

    assert {:ok, fleet} = Fleet.load(manifest_path)
    assert Fleet.effective_shared_paths(fleet) == []
  end

  test "a non-string-list manifest-level shared_paths is a load-time error naming the manifest",
       %{dir: dir} do
    write_goal(dir, "0001-a.goal.toml", "a")

    manifest = """
    shared_paths = "mix.exs"

    [[member]]
    path = "0001-a.goal.toml"
    """

    manifest_path = Path.join(dir, "fleet.toml")
    File.write!(manifest_path, manifest)

    assert {:error, message} = Fleet.load(manifest_path)
    assert message =~ "shared_paths"
    assert message =~ "fleet.toml"
  end
end

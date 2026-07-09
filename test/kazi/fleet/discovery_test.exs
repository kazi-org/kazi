defmodule Kazi.Fleet.DiscoveryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kazi.CLI
  alias Kazi.Fleet.Discovery

  @basic_dir "test/kazi/fleet/fixtures/basic"
  @cycle_dir "test/kazi/fleet/fixtures/cycle"
  @dangling_dir "test/kazi/fleet/fixtures/dangling"

  describe "discover/1" do
    test "builds the expected DAG: explicit edge, inferred overlap, independent pair" do
      assert {:ok, %Discovery{} = fleet} = Discovery.discover(@basic_dir)

      assert Enum.map(fleet.members, & &1.goal.id) == ["fleet-a", "fleet-b", "fleet-c"]

      # fleet-b explicitly depends_on fleet-a.
      assert %{from: "fleet-a", to: "fleet-b", kind: :explicit} in fleet.edges

      # fleet-a and fleet-c have overlapping [scope] paths (lib/a/** vs
      # lib/a/sub/**) and no explicit edge -- inferred, deterministic direction
      # (lexicographically smaller id first).
      assert %{from: "fleet-a", to: "fleet-c", kind: :inferred_overlap} in fleet.edges

      # fleet-b and fleet-c are fully independent: no explicit edge, disjoint
      # scope (lib/b/** vs lib/a/sub/**) -- no edge between them at all.
      refute Enum.any?(fleet.edges, fn %{from: from, to: to} ->
               MapSet.new([from, to]) == MapSet.new(["fleet-b", "fleet-c"])
             end)

      assert length(fleet.edges) == 2

      # Topological frontiers: fleet-a alone (nothing needs to precede it),
      # then fleet-b and fleet-c together (both only depend on fleet-a).
      assert fleet.frontiers == [["fleet-a"], ["fleet-b", "fleet-c"]]
    end

    test "a dependency cycle fails load, naming the cycle's file paths" do
      assert {:error, message} = Discovery.discover(@cycle_dir)

      assert message =~ "dependency cycle"
      assert message =~ "fixtures/cycle/fleet-x.goal.toml"
      assert message =~ "fixtures/cycle/fleet-y.goal.toml"
    end

    test "a depends_on entry naming a nonexistent goal-id fails load, naming the dangling reference" do
      assert {:error, message} = Discovery.discover(@dangling_dir)

      assert message =~ "fixtures/dangling/fleet-only.goal.toml"
      assert message =~ "fleet-ghost"
    end
  end

  describe "kazi apply --fleet <dir> --explain --json" do
    test "renders the fleet's computed schedule without dispatching anything" do
      argv = ["apply", "--fleet", @basic_dir, "--explain", "--json"]

      output = capture_io(fn -> assert CLI.run(argv) == 0 end)

      assert %{"mode" => "fleet_explain", "dispatched" => false} = decoded = Jason.decode!(output)

      assert decoded["goals"] == ["fleet-a", "fleet-b", "fleet-c"]

      assert decoded["frontiers"] == [
               %{"frontier" => 0, "goals" => ["fleet-a"]},
               %{"frontier" => 1, "goals" => ["fleet-b", "fleet-c"]}
             ]

      edge_kinds =
        decoded["edges"]
        |> Enum.map(fn %{"from" => from, "to" => to, "kind" => kind} -> {from, to, kind} end)
        |> Enum.sort()

      assert edge_kinds == [
               {"fleet-a", "fleet-b", "explicit"},
               {"fleet-a", "fleet-c", "inferred_overlap"}
             ]
    end

    test "a cycle fails the CLI call and reports the offending files under --json" do
      argv = ["apply", "--fleet", @cycle_dir, "--explain", "--json"]

      output = capture_io(fn -> assert CLI.run(argv) == 1 end)

      assert %{"error" => message} = Jason.decode!(output)
      assert message =~ "dependency cycle"
    end
  end
end

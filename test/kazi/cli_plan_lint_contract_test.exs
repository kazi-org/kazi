defmodule Kazi.CLIPlanLintContractTest do
  @moduledoc """
  T73.6: `kazi plan lint <roadmap>` fails (non-zero exit) when a member
  goal's `write_paths` covers ANOTHER member's declared `[scope].contract`,
  naming both goal ids and the shared path — the fleet-level extension of
  `Kazi.CLILintContractTest`'s single-goal self-check, run alongside the
  existing nesting-conflict check (`Kazi.CLIPlanLintTest`).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kazi-plan-lint-contract-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp goal_file(dir, filename, id, write_paths, contract) do
    path = Path.join(dir, filename)

    contract_line = if contract, do: "contract = \"#{contract}\"\n", else: ""

    File.write!(path, """
    id = "#{id}"

    [scope]
    write_paths = #{inspect(write_paths)}
    #{contract_line}
    [[predicate]]
    id = "p"
    provider = "custom_script"
    cmd = "true"
    """)

    path
  end

  defp roadmap_file(dir, filename, entries) do
    path = Path.join(dir, filename)

    body =
      Enum.map_join(entries, "\n\n", fn {roadmap_id, goal_path} ->
        """
        [[goals]]
        id = "#{roadmap_id}"
        path = "#{Path.basename(goal_path)}"
        """
      end)

    File.write!(path, body)
    path
  end

  # A's own write scope ("lib/foo/**") and contract ("lib/contracts/foo.ex")
  # are disjoint (so A alone passes `kazi lint`'s single-goal self-check) and
  # B's write scope ("lib/contracts/**") is disjoint from A's own root too (so
  # the EXISTING nesting-conflict check stays clean and this test isolates
  # the NEW contract-write check).
  describe "B's write_paths covering A's contract refuses, naming A, B, and the path" do
    test "human surface", %{dir: dir} do
      a = goal_file(dir, "a.goal.toml", "goal-a", ["lib/foo/**"], "lib/contracts/foo.ex")
      b = goal_file(dir, "b.goal.toml", "goal-b", ["lib/contracts/**"], nil)
      roadmap = roadmap_file(dir, "conflict.roadmap.toml", [{"a", a}, {"b", b}])

      out =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["plan", "lint", roadmap]) == 1
        end)

      assert out =~ "error:"
      assert out =~ "\"a\""
      assert out =~ "\"b\""
      assert out =~ "lib/contracts/foo.ex"
    end

    test "--json names A, B, the path, and reason contract_write_conflict", %{dir: dir} do
      a = goal_file(dir, "a.goal.toml", "goal-a", ["lib/foo/**"], "lib/contracts/foo.ex")
      b = goal_file(dir, "b.goal.toml", "goal-b", ["lib/contracts/**"], nil)
      roadmap = roadmap_file(dir, "conflict.roadmap.toml", [{"a", a}, {"b", b}])

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "lint", roadmap, "--json"]) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "contract_write_conflict"
      assert payload["conflicts"] == []
      assert [conflict] = payload["contract_conflicts"]
      assert conflict["owner"] == "a"
      assert conflict["writer"] == "b"
      assert conflict["path"] == "lib/contracts/foo.ex"
    end
  end

  describe "disjoint write scopes and contracts pass" do
    test "--json reports empty conflict lists (exit 0)", %{dir: dir} do
      a = goal_file(dir, "a.goal.toml", "goal-a", ["lib/foo/**"], "lib/contracts/foo.ex")
      b = goal_file(dir, "b.goal.toml", "goal-b", ["lib/bar/**"], "lib/contracts/bar.ex")
      roadmap = roadmap_file(dir, "clean.roadmap.toml", [{"a", a}, {"b", b}])

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["plan", "lint", roadmap, "--json"]) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["conflicts"] == []
      assert payload["contract_conflicts"] == []
    end
  end
end

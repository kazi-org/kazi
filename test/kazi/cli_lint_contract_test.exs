defmodule Kazi.CLILintContractTest do
  @moduledoc """
  T73.6: `kazi lint <goal-file>` fails (non-zero exit) a goal whose own
  `write_paths`/`paths` covers its own declared `[scope].contract` — UNLIKE
  the existing advisory near-duplicate-group-name net (`Kazi.CLILintTest`),
  which never fails a goal that loads. A contract outside the goal's own
  write scope passes.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  setup do
    dir =
      Path.join(System.tmp_dir!(), "kazi-cli-lint-contract-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp goal_file(dir, id, write_paths, contract) do
    path = Path.join(dir, "#{id}.goal.toml")

    File.write!(path, """
    id = "#{id}"

    [scope]
    write_paths = #{inspect(write_paths)}
    contract = "#{contract}"

    [[predicate]]
    id = "p"
    provider = "custom_script"
    cmd = "true"
    """)

    path
  end

  describe "a goal writing lib/foo/** with contract lib/foo/contract.ex fails, naming both" do
    test "human surface" do
      dir = Path.join(System.tmp_dir!(), "kazi-lint-c1-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      goal = goal_file(dir, "self-conflict", ["lib/foo/**"], "lib/foo/contract.ex")

      out =
        capture_io(:stderr, fn ->
          assert Kazi.CLI.run(["lint", goal]) == 1
        end)

      assert out =~ "error:"
      assert out =~ "lib/foo/**"
      assert out =~ "lib/foo/contract.ex"
    end

    test "--json names the goal, root, and contract, with reason contract_write_conflict" do
      dir = Path.join(System.tmp_dir!(), "kazi-lint-c2-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      goal = goal_file(dir, "self-conflict", ["lib/foo/**"], "lib/foo/contract.ex")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["lint", goal, "--json"]) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "contract_write_conflict"
      assert payload["goal_id"] == "self-conflict"
      assert payload["root"] == "lib/foo/**"
      assert payload["contract"] == "lib/foo/contract.ex"
    end
  end

  describe "a contract outside the goal's own write_paths passes" do
    test "exits 0" do
      dir = Path.join(System.tmp_dir!(), "kazi-lint-c3-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      goal = goal_file(dir, "no-conflict", ["lib/foo/**"], "lib/contracts/foo.ex")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(["lint", goal]) == 0
        end)

      refute out =~ "error:"
    end
  end
end

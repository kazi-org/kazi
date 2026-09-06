defmodule Kazi.CLICheckNodeShaTest do
  @moduledoc """
  T72.6 (ADR-0086 decision 5): `kazi apply --check --node-sha <sha256>` —
  the lane adapter's own freshness hook (the dispatcher-side render/pin lives
  in the fleet repo, out of scope here). Re-renders the goal's first declared
  scope root's node from the goal-file (the SAME machinery
  `--lane-contract`'s `render_sha256` check already uses, pinned in
  `test/kazi/cli_lane_contract_render_test.exs`) and compares its sha256
  against the given digest — never dispatching a harness (observe-only, like
  `--check` alone).

  Covers: a matching sha passes (exit 0); a one-byte-changed sha fails (exit
  1, naming both digests); `--node-sha` with no `--check` is rejected before
  any observation; a goal with no declared `[scope]` root refuses (there is
  no node to check against).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Plan.Render, as: PlanRender
  alias Kazi.Repo

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "a matching --node-sha passes, exit 0", %{tmp_dir: tmp_dir} do
    work = git_repo_fixture(tmp_dir)
    goal_file = write_scoped_goal_file(tmp_dir, work)
    sha = expected_node_sha256(goal_file, work)

    out =
      capture_io(fn ->
        assert Kazi.CLI.run([
                 "apply",
                 goal_file,
                 "--workspace",
                 work,
                 "--check",
                 "--node-sha",
                 sha,
                 "--json"
               ]) == 0
      end)

    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert payload["status"] == "match"
    assert payload["node_sha256"] == sha
  end

  test "a one-byte-changed --node-sha fails, exit 1, naming both digests", %{tmp_dir: tmp_dir} do
    work = git_repo_fixture(tmp_dir)
    goal_file = write_scoped_goal_file(tmp_dir, work)
    wrong_sha = String.duplicate("0", 64)

    out =
      capture_io(fn ->
        assert Kazi.CLI.run([
                 "apply",
                 goal_file,
                 "--workspace",
                 work,
                 "--check",
                 "--node-sha",
                 wrong_sha,
                 "--json"
               ]) == 1
      end)

    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert payload["status"] == "mismatch"
    assert payload["expected_node_sha256"] == wrong_sha
    assert is_binary(payload["actual_node_sha256"])
    refute payload["actual_node_sha256"] == wrong_sha
  end

  test "--node-sha without --check is refused before any observation", %{tmp_dir: tmp_dir} do
    work = git_repo_fixture(tmp_dir)
    goal_file = write_scoped_goal_file(tmp_dir, work)

    out =
      capture_io(:stderr, fn ->
        assert Kazi.CLI.run([
                 "apply",
                 goal_file,
                 "--workspace",
                 work,
                 "--node-sha",
                 String.duplicate("0", 64)
               ]) == 1
      end)

    assert out =~ "--node-sha requires --check"
  end

  test "a goal with no declared [scope] root refuses", %{tmp_dir: tmp_dir} do
    work = git_repo_fixture(tmp_dir)
    goal_file = write_unscoped_goal_file(tmp_dir, work)

    out =
      capture_io(:stderr, fn ->
        assert Kazi.CLI.run([
                 "apply",
                 goal_file,
                 "--workspace",
                 work,
                 "--check",
                 "--node-sha",
                 String.duplicate("0", 64)
               ]) == 1
      end)

    assert out =~ "declares no [scope] root"
  end

  # --- fixtures ------------------------------------------------------------

  defp git_repo_fixture(tmp_dir) do
    work = Path.join(tmp_dir, "repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", work], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: work)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: work)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: work)
    File.write!(Path.join(work, "seed.txt"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: work, stderr_to_stdout: true)
    work
  end

  defp write_scoped_goal_file(tmp_dir, workspace) do
    path =
      Path.join(tmp_dir, "node-sha-fixture-#{System.unique_integer([:positive])}.goal.toml")

    File.write!(path, """
    id = "cli-node-sha-fixture"
    name = "CLI node-sha fixture"

    [scope]
    workspace = #{inspect(workspace)}
    paths = ["."]

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  defp write_unscoped_goal_file(tmp_dir, workspace) do
    path =
      Path.join(
        tmp_dir,
        "node-sha-unscoped-fixture-#{System.unique_integer([:positive])}.goal.toml"
      )

    File.write!(path, """
    id = "cli-node-sha-unscoped-fixture"
    name = "CLI node-sha unscoped fixture"

    [scope]
    workspace = #{inspect(workspace)}

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  # Computes the SAME sha256 `check_node_sha/3` will compute at run time.
  defp expected_node_sha256(goal_file, workspace) do
    {:ok, goal} = Kazi.Goal.Loader.load(goal_file)
    {:ok, %{vector: vector}} = Kazi.Runtime.check(goal, workspace: workspace)
    [root | _] = Kazi.Scope.roots(goal.scope)
    content = PlanRender.node(goal, root, vector)
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end

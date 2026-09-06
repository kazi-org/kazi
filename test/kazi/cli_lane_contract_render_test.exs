defmodule Kazi.CLILaneContractRenderTest do
  @moduledoc """
  TKE.2 (ADR-0086 decision 5(b), docs/plans/E-KAZI-ENTRYPOINT.md 1.1): the
  render-freshness check chained after TKE.1's task_sha match, still before
  any predicate observation for the real run or any harness dispatch.

  Three contracts, each driven through the REAL CLI exec core
  (`Kazi.CLI.run/2`), mirroring `cli_lane_contract_test.exs`'s style:

    1. `render_sha256` matches the freshly re-rendered node -> proceeds,
       converges, dispatches the harness.
    2. `render_sha256` present but WRONG -> refuses before dispatch, `kind:
       "stale_render"`, naming both shas (proves this is not a vacuous
       always-true predicate: the SAME contract with the RIGHT sha, above,
       passes; this one, differing only in that field, refuses).
    3. `render_sha256` ABSENT from an otherwise-valid (matching task_sha)
       contract -> refuses, `kind: "render_sha256_missing"` -- fail-closed,
       not silently skipped.

  Plus: a goal with NO declared `[scope]` paths (the TKE.1 fixture shape) is
  scopeless (`Kazi.Scope.roots/1` returns `[]`) and this check never applies
  -- proven by reusing a TKE.1-style contract with no `render_sha256` that
  still converges.

  HERMETIC: a real (throwaway) git repo per test, same as
  `cli_lane_contract_test.exs`.
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

  describe "render_sha256 matches the freshly re-rendered node" do
    test "proceeds unchanged: converges, dispatches the harness", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      sha = head_sha(work)
      goal_file = write_scoped_goal_file(tmp_dir, work)
      render_sha = expected_render_sha256(goal_file, work)
      contract = write_contract_file(tmp_dir, sha, render_sha)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--single-node",
                     "--in-place",
                     "--allow-primary-workspace",
                     "--lane-contract",
                     contract,
                     "--json"
                   ],
                   adapter_opts: [command: passing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "converged"
      assert payload["reason"] == nil
      refute Map.has_key?(payload, "kind")
      assert File.exists?(Path.join(work, "fixed.txt")), "the harness DID run"
    end
  end

  describe "render_sha256 present but wrong" do
    test "refuses before dispatch: kind stale_render, naming both shas, exit 1",
         %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      sha = head_sha(work)
      goal_file = write_scoped_goal_file(tmp_dir, work)
      wrong_render_sha = String.duplicate("0", 64)
      contract = write_contract_file(tmp_dir, sha, wrong_render_sha)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--single-node",
                     "--in-place",
                     "--allow-primary-workspace",
                     "--lane-contract",
                     contract,
                     "--json"
                   ],
                   adapter_opts: [command: never_called_harness(tmp_dir)]
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "lane_contract_violation"
      assert payload["kind"] == "stale_render"
      assert payload["render_sha256"] == wrong_render_sha
      assert is_binary(payload["actual_render_sha256"])
      refute payload["actual_render_sha256"] == wrong_render_sha

      refute File.exists?(harness_called_marker(tmp_dir)),
             "the render-freshness guard must fire BEFORE any dispatch"
    end
  end

  describe "render_sha256 absent from an otherwise-valid contract" do
    test "refuses: kind render_sha256_missing, exit 1, no dispatch", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      sha = head_sha(work)
      goal_file = write_scoped_goal_file(tmp_dir, work)
      contract = write_contract_file_no_render_sha(tmp_dir, sha)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--single-node",
                     "--in-place",
                     "--allow-primary-workspace",
                     "--lane-contract",
                     contract,
                     "--json"
                   ],
                   adapter_opts: [command: never_called_harness(tmp_dir)]
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "lane_contract_violation"
      assert payload["kind"] == "render_sha256_missing"
      refute File.exists?(harness_called_marker(tmp_dir))
    end
  end

  describe "a scopeless goal (no declared [scope] paths)" do
    test "skips the render-freshness check entirely, even with no render_sha256",
         %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      sha = head_sha(work)
      goal_file = write_unscoped_goal_file(tmp_dir, work)
      contract = write_contract_file_no_render_sha(tmp_dir, sha)

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--single-node",
                     "--in-place",
                     "--allow-primary-workspace",
                     "--lane-contract",
                     contract,
                     "--json"
                   ],
                   adapter_opts: [command: passing_harness(tmp_dir)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "converged"
      refute Map.has_key?(payload, "kind")
    end
  end

  # ===========================================================================
  # helpers
  # ===========================================================================

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

  defp head_sha(work) do
    {out, 0} = System.cmd("git", ["-C", work, "rev-parse", "HEAD"])
    String.trim(out)
  end

  # Declares a `[scope] paths` so `Kazi.Scope.roots/1` is non-empty -- the
  # render-freshness check only applies to a goal with a declared scope root
  # (ADR-0086 decision 3).
  defp write_scoped_goal_file(tmp_dir, workspace) do
    path =
      Path.join(
        tmp_dir,
        "lane-contract-render-fixture-#{System.unique_integer([:positive])}.goal.toml"
      )

    File.write!(path, """
    id = "cli-lane-contract-render-fixture"
    name = "CLI lane-contract render fixture"

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

  # Mirrors `cli_lane_contract_test.exs`'s TKE.1 fixture: no `paths` declared
  # at all, so `Kazi.Scope.roots/1` returns `[]` -- scopeless.
  defp write_unscoped_goal_file(tmp_dir, workspace) do
    path =
      Path.join(
        tmp_dir,
        "lane-contract-unscoped-fixture-#{System.unique_integer([:positive])}.goal.toml"
      )

    File.write!(path, """
    id = "cli-lane-contract-unscoped-fixture"
    name = "CLI lane-contract unscoped fixture"

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

  defp write_contract_file(tmp_dir, task_sha, render_sha256) do
    path = Path.join(tmp_dir, "contract-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        schema_version: 1,
        run_id: "run-#{System.unique_integer([:positive])}",
        task: "TKE.2 fixture",
        task_sha: task_sha,
        render_sha256: render_sha256,
        goal: "cli-lane-contract-render-fixture",
        predicates: ["code"]
      })
    )

    path
  end

  defp write_contract_file_no_render_sha(tmp_dir, task_sha) do
    path = Path.join(tmp_dir, "contract-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        schema_version: 1,
        run_id: "run-#{System.unique_integer([:positive])}",
        task: "TKE.2 fixture (no render_sha256)",
        task_sha: task_sha,
        goal: "cli-lane-contract-render-fixture",
        predicates: ["code"]
      })
    )

    path
  end

  # Computes the SAME sha256 `render_freshness_check/4` will compute at run
  # time: a fresh `Kazi.Runtime.check/2` observe pass, fed into
  # `Kazi.Plan.Render.node/3`, hashed. The predicate fails at t0 (no
  # `fixed.txt` yet) exactly as the real run's own t0 observation would see.
  defp expected_render_sha256(goal_file, workspace) do
    {:ok, goal} = Kazi.Goal.Loader.load(goal_file)
    {:ok, %{vector: vector}} = Kazi.Runtime.check(goal, workspace: workspace)
    [root | _] = Kazi.Scope.roots(goal.scope)
    content = PlanRender.node(goal, root, vector)
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp harness_called_marker(tmp_dir), do: Path.join(tmp_dir, "harness-called")

  defp never_called_harness(tmp_dir) do
    write_stub(tmp_dir, "never-called", "touch #{harness_called_marker(tmp_dir)}\nexit 0")
  end

  defp passing_harness(tmp_dir) do
    write_stub(tmp_dir, "passing", "echo \"the converged fix\" > fixed.txt\nexit 0")
  end

  defp write_stub(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "stub-#{name}-#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end
end

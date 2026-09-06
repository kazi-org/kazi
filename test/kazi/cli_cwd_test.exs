defmodule Kazi.CLICwdTest do
  @moduledoc """
  T72.7 (ADR-0086 decision 7): `kazi apply --cwd <dir>` -- the harness launches
  in the given directory inside the dispatch workspace, defaulting to the
  goal's first declared `[scope]` root; a `--cwd` resolving outside the
  workspace refuses before any predicate observation or harness dispatch.

  HERMETIC: a real (throwaway) git repo per test, the same stub-harness
  pattern `cli_resume_pr_test.exs`/`cli_lane_contract_render_test.exs` use --
  the harness dispatch record is real: a stub shell script writes `pwd` to a
  marker file, so the assertion is on what the real `Kazi.HarnessAdapter.CliAdapter`
  spawn actually received as its `cd:` option, not a mock's recorded args.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Repo

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "a goal rooted at pkg/foo, no --cwd" do
    test "the harness spawn receives cwd = worktree/pkg/foo", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      File.mkdir_p!(Path.join(work, "pkg/foo"))
      goal_file = write_scoped_goal_file(tmp_dir, work, "pkg/foo")
      cwd_marker = Path.join(tmp_dir, "cwd.marker")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--in-place",
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--json"
                   ],
                   adapter_opts: [command: pwd_recording_harness(tmp_dir, cwd_marker, work)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "converged"

      assert File.exists?(cwd_marker), "the harness DID dispatch"
      recorded_cwd = File.read!(cwd_marker) |> String.trim()
      assert recorded_cwd == Path.expand(Path.join(work, "pkg/foo"))
    end
  end

  describe "an explicit --cwd" do
    test "overrides the default scope-root cwd", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      File.mkdir_p!(Path.join(work, "pkg/foo"))
      File.mkdir_p!(Path.join(work, "pkg/bar"))
      goal_file = write_scoped_goal_file(tmp_dir, work, "pkg/foo")
      cwd_marker = Path.join(tmp_dir, "cwd.marker")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--in-place",
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--cwd",
                     "pkg/bar",
                     "--json"
                   ],
                   adapter_opts: [command: pwd_recording_harness(tmp_dir, cwd_marker, work)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 0
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["status"] == "converged"

      recorded_cwd = File.read!(cwd_marker) |> String.trim()
      assert recorded_cwd == Path.expand(Path.join(work, "pkg/bar"))
    end
  end

  describe "--cwd resolving outside the workspace" do
    test "exits non-zero before any harness dispatch", %{tmp_dir: tmp_dir} do
      work = git_repo_fixture(tmp_dir)
      goal_file = write_unscoped_goal_file(tmp_dir, work)
      dispatch_marker = Path.join(tmp_dir, "dispatched.marker")

      out =
        capture_io(fn ->
          assert Kazi.CLI.run(
                   [
                     "apply",
                     goal_file,
                     "--workspace",
                     work,
                     "--in-place",
                     "--allow-primary-workspace",
                     "--no-preflight",
                     "--cwd",
                     "../outside",
                     "--json"
                   ],
                   adapter_opts: [command: marking_harness(tmp_dir, dispatch_marker)],
                   reobserve_interval_ms: 5,
                   await_timeout: 15_000
                 ) == 1
        end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["reason"] == "cwd_outside_worktree"
      refute File.exists?(dispatch_marker), "no harness dispatch on a refused --cwd"
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

  defp write_scoped_goal_file(tmp_dir, workspace, root) do
    path = Path.join(tmp_dir, "cwd-fixture-#{System.unique_integer([:positive])}.goal.toml")

    File.write!(path, """
    id = "cli-cwd-fixture"
    name = "CLI --cwd fixture"

    [scope]
    workspace = #{inspect(workspace)}
    paths = [#{inspect(root)}]

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
      Path.join(tmp_dir, "cwd-unscoped-fixture-#{System.unique_integer([:positive])}.goal.toml")

    File.write!(path, """
    id = "cli-cwd-unscoped-fixture"
    name = "CLI --cwd unscoped fixture"

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

  # Writes `pwd` to `marker_path` (proving the REAL cwd the subprocess actually
  # launched in) and satisfies the predicate at the WORKSPACE root via an
  # absolute path (the predicate itself is observed against the workspace
  # root regardless of the harness's own launch cwd -- only the dispatch
  # target moves, T72.7), so the run converges.
  defp pwd_recording_harness(tmp_dir, marker_path, workspace) do
    write_stub(tmp_dir, "pwd-recording", """
    pwd > #{marker_path}
    echo "the converged fix" > #{Path.join(workspace, "fixed.txt")}
    """)
  end

  # Never actually satisfies the predicate -- only used to prove it was never
  # invoked at all (a refused run must dispatch nothing).
  defp marking_harness(tmp_dir, marker_path) do
    write_stub(tmp_dir, "marking", "touch #{marker_path}\nexit 1")
  end

  defp write_stub(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "stub-#{name}-#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end
end

defmodule Kazi.CLI.SerialWorktreeIndirectionTest do
  @moduledoc """
  T50.1 (ADR-0065) acceptance: a non-`--parallel` executing `apply` routes
  through the group scheduler's EXISTING worktree indirection (T21.4) instead
  of editing `--workspace` in place. This pins the CLI wiring; the worktree
  mechanism itself (create-on-start, remove-on-terminal, the guard against
  ever `rm`-ing a cwd/repo path) is already pinned by
  `Kazi.Scheduler.WorktreeTest`.

  Contract pinned here:

    * the DEFAULT serial path leaves the base checkout BYTE-IDENTICAL
      (untracked files included) while the goal converges in a kazi-owned
      worktree (the fixer's cwd is some OTHER path, never the base, and that
      path is gone once the run terminates);
    * `--in-place` reproduces today's pre-E50 direct-edit behavior exactly
      (the fixer's cwd IS the base, and the fix lands there);
    * guard interplay (issue #937 Gap A): a primary-worktree workspace is
      still REFUSED under `--in-place` without `--allow-primary-workspace`,
      but the DEFAULT worktree-indirected path runs the SAME primary-worktree
      workspace with NO refusal at all -- it never touches the caller's
      checkout, so the guard has nothing to protect there.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    :ok
  end

  describe "default (worktree-indirected)" do
    test "the base checkout stays byte-identical while the goal converges in a kazi-owned worktree",
         %{tmp_dir: tmp_dir} do
      base = fixture_repo(tmp_dir)
      scratch = Path.join(base, "scratch.txt")
      File.write!(scratch, "untouched scratch state\n")

      goal_file = write_goal_file(tmp_dir, base)
      cwd_marker = Path.join(tmp_dir, "harness-cwd")
      worktree_base_dir = Path.join(tmp_dir, "kazi-worktrees")

      before_status = git_status(base)

      {code, _out} =
        with_io(fn ->
          Kazi.CLI.run(
            ["apply", goal_file, "--workspace", base, "--json"],
            adapter_opts: [command: recording_harness(tmp_dir, cwd_marker)],
            worktree: [base_dir: worktree_base_dir],
            reobserve_interval_ms: 5,
            await_timeout: 60_000
          )
        end)

      assert code == 0

      # The fixer ran somewhere else entirely -- never the base workspace.
      recorded_cwd = cwd_marker |> File.read!() |> String.trim()
      refute Path.expand(recorded_cwd) == Path.expand(base)
      assert String.starts_with?(Path.expand(recorded_cwd), Path.expand(worktree_base_dir))

      # The base checkout is BYTE-IDENTICAL: the fix never landed there, the
      # untracked scratch file is untouched, and `git status` is unchanged.
      refute File.exists?(Path.join(base, "fixed.txt"))
      assert File.read!(scratch) == "untouched scratch state\n"
      assert git_status(base) == before_status

      # The worktree itself is gone -- cleaned up on terminal (T21.4).
      refute File.dir?(recorded_cwd)
    end

    test "a primary-worktree workspace runs with NO refusal -- it never touches the checkout",
         %{tmp_dir: tmp_dir} do
      base = fixture_repo(tmp_dir)
      goal_file = write_goal_file(tmp_dir, base)
      cwd_marker = Path.join(tmp_dir, "harness-cwd")

      {code, out} =
        with_io(fn ->
          Kazi.CLI.run(
            ["apply", goal_file, "--workspace", base, "--json"],
            adapter_opts: [command: recording_harness(tmp_dir, cwd_marker)],
            worktree: [base_dir: Path.join(tmp_dir, "kazi-worktrees")],
            reobserve_interval_ms: 5,
            await_timeout: 60_000
          )
        end)

      refute out =~ "PRIMARY worktree"
      assert code == 0
    end
  end

  describe "--in-place" do
    test "reproduces today's direct-edit behavior exactly", %{tmp_dir: tmp_dir} do
      base = fixture_repo(tmp_dir)
      goal_file = write_goal_file(tmp_dir, base)
      cwd_marker = Path.join(tmp_dir, "harness-cwd")

      {code, _out} =
        with_io(fn ->
          Kazi.CLI.run(
            ["apply", goal_file, "--workspace", base, "--in-place", "--json"],
            adapter_opts: [command: recording_harness(tmp_dir, cwd_marker)],
            reobserve_interval_ms: 5,
            await_timeout: 60_000
          )
        end)

      assert code == 0

      recorded_cwd = cwd_marker |> File.read!() |> String.trim()
      assert Path.expand(recorded_cwd) == Path.expand(base)
      assert File.exists?(Path.join(base, "fixed.txt"))
    end

    test "a primary-worktree workspace is REFUSED without --allow-primary-workspace",
         %{tmp_dir: tmp_dir} do
      base = fixture_repo(tmp_dir)
      goal_file = write_goal_file(tmp_dir, base)
      marker = Path.join(tmp_dir, "harness-called")

      {out, code} =
        with_io(fn ->
          Kazi.CLI.run(
            ["apply", goal_file, "--workspace", base, "--in-place", "--json"],
            adapter_opts: [command: never_called_harness(tmp_dir, marker)]
          )
        end)
        |> then(fn {c, o} -> {o, c} end)

      assert code == 1
      assert %{"error" => message} = Jason.decode!(out)
      assert message =~ "PRIMARY worktree"
      refute File.exists?(marker), "the guard must fire BEFORE any dispatch"
    end

    test "--allow-primary-workspace runs it", %{tmp_dir: tmp_dir} do
      base = fixture_repo(tmp_dir)
      goal_file = write_goal_file(tmp_dir, base)
      cwd_marker = Path.join(tmp_dir, "harness-cwd")

      {code, _out} =
        with_io(fn ->
          Kazi.CLI.run(
            [
              "apply",
              goal_file,
              "--workspace",
              base,
              "--in-place",
              "--allow-primary-workspace",
              "--json"
            ],
            adapter_opts: [command: recording_harness(tmp_dir, cwd_marker)],
            reobserve_interval_ms: 5,
            await_timeout: 60_000
          )
        end)

      assert code == 0
    end
  end

  # --- fixtures ---------------------------------------------------------

  # A primary (non-linked) git repo with one commit, matching the shape
  # `primary_workspace_refused?/2` refuses.
  defp fixture_repo(tmp_dir) do
    work = Path.join(tmp_dir, "base-#{System.unique_integer([:positive])}")
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

  defp git_status(repo) do
    {out, 0} = System.cmd("git", ["status", "--porcelain"], cd: repo)
    out
  end

  # A predicate that FAILS at t0 (`test -f fixed.txt`) so the goal is never
  # vacuous, satisfied by a stub harness that writes the file into its cwd.
  defp write_goal_file(tmp_dir, workspace) do
    # A UNIQUE goal id per call: several tests in this file dispatch the
    # SAME-shaped goal in quick succession, and a shared id could trip the
    # run registry's live-duplicate guard on a slow/contended read-model
    # before the prior test's run is marked finished.
    id = "t50-1-fixture-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "#{id}.goal.toml")

    File.write!(path, """
    id = #{inspect(id)}
    name = "t50.1 fixture"

    [scope]
    workspace = #{inspect(workspace)}

    [budget]
    max_iterations = 10

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  # Records its OWN cwd (via `pwd`) to `cwd_marker`, then converges the goal.
  defp recording_harness(tmp_dir, cwd_marker) do
    write_stub(
      tmp_dir,
      "recording",
      "pwd > #{cwd_marker}\necho \"the converged fix\" > fixed.txt\nexit 0"
    )
  end

  defp never_called_harness(tmp_dir, marker) do
    write_stub(tmp_dir, "never-called", "touch #{marker}\nexit 0")
  end

  defp write_stub(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "stub-#{name}-#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end
end

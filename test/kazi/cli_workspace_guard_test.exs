defmodule Kazi.CLIWorkspaceGuardTest do
  @moduledoc """
  Issue #937 Gap A: an EXECUTING `kazi apply` refuses a workspace that is a git
  repo's PRIMARY (non-linked) worktree unless `--allow-primary-workspace`.

  The incident this pins against: a serial apply pointed at a real shared
  checkout converged its own work, and the dispatched agent's shell then
  reset/cleaned the whole tree -- destroying a CONCURRENT session's untracked
  files (docs/lore.md L-0034). kazi core never runs `git reset`/`git clean`
  itself, so the guard is a tripwire at the one place kazi CAN intervene: the
  decision to execute against that workspace at all.

  Contract, all four directions:

    1. a primary-worktree workspace is REFUSED (JSON error + exit 1, nothing
       dispatched);
    2. `--allow-primary-workspace` runs it;
    3. a LINKED worktree workspace runs without the flag (the sanctioned
       isolation pattern must stay zero-friction);
    4. a non-git workspace runs without the flag (unchanged behavior);

  plus: read-only `--check` stays available on a primary worktree without the
  flag (inspecting a live checkout is safe and load-bearing for triage).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    :ok
  end

  test "an executing --in-place apply REFUSES a primary-worktree workspace: JSON error, exit 1, no dispatch",
       %{tmp_dir: tmp_dir} do
    # T50.1 (ADR-0065 decision 1): the guard now applies only to --in-place --
    # the DEFAULT serial path isolates into a task worktree, making the
    # dangerous target unreachable (see test/kazi/serial_worktree_indirection_test.exs).
    work = primary_repo(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work)

    {out, code} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--in-place", "--json"],
          adapter_opts: [command: never_called_harness(tmp_dir)]
        )
      end)
      |> then(fn {code, out} -> {out, code} end)

    assert code == 1
    assert %{"error" => message} = Jason.decode!(out)
    assert message =~ "PRIMARY worktree"
    assert message =~ "--allow-primary-workspace"
    refute File.exists?(harness_called_marker(tmp_dir)), "the guard must fire BEFORE any dispatch"
  end

  test "--allow-primary-workspace runs the same workspace", %{tmp_dir: tmp_dir} do
    work = primary_repo(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work)

    {code, _out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--allow-primary-workspace", "--json"],
          adapter_opts: [command: passing_harness(tmp_dir)],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)

    assert code == 0
  end

  test "a LINKED worktree workspace runs without the flag", %{tmp_dir: tmp_dir} do
    primary = primary_repo(tmp_dir)
    linked = Path.join(tmp_dir, "linked")

    {_, 0} =
      System.cmd("git", ["worktree", "add", "-b", "task-branch", linked],
        cd: primary,
        stderr_to_stdout: true
      )

    goal_file = write_goal_file(tmp_dir, linked)

    {code, _out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", linked, "--json"],
          adapter_opts: [command: passing_harness(tmp_dir)],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)

    assert code == 0
  end

  test "a non-git workspace runs without the flag", %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "plain")
    File.mkdir_p!(work)
    goal_file = write_goal_file(tmp_dir, work)

    {code, _out} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--json"],
          adapter_opts: [command: passing_harness(tmp_dir)],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)

    assert code == 0
  end

  test "read-only --check stays available on a primary worktree without the flag",
       %{tmp_dir: tmp_dir} do
    work = primary_repo(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work)

    {code, out} =
      with_io(fn ->
        Kazi.CLI.run(["apply", goal_file, "--workspace", work, "--check", "--json"], [])
      end)

    # --check observes the (failing-at-t0) vector and exits non-zero on a
    # non-converged goal -- the point here is ONLY that the guard did not fire:
    # the output is a check result, not the primary-worktree refusal.
    refute out =~ "PRIMARY worktree"
    assert is_integer(code)
  end

  # --- fixtures -------------------------------------------------------------

  # A primary (non-linked) worktree: plain `git init` + one commit.
  defp primary_repo(tmp_dir) do
    work = Path.join(tmp_dir, "primary")
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

  # The run-registry wiring test's proven fixture shape: a predicate that FAILS
  # at t0 (`test -f fixed.txt`) so the goal is never vacuous, satisfied by a
  # stub harness that writes the file into the workspace cwd.
  defp write_goal_file(tmp_dir, workspace) do
    path = Path.join(tmp_dir, "guard-#{System.unique_integer([:positive])}.goal.toml")

    File.write!(path, """
    id = "workspace-guard-fixture"
    name = "workspace guard fixture"

    [scope]
    workspace = #{inspect(workspace)}

    [budget]
    max_iterations = 3

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  # A stub harness that records it was invoked (the refusal test asserts the
  # marker is ABSENT) -- if the guard leaks a dispatch through, this fails loudly.
  defp harness_called_marker(tmp_dir), do: Path.join(tmp_dir, "harness-called")

  defp never_called_harness(tmp_dir) do
    write_stub(tmp_dir, "never-called", "touch #{harness_called_marker(tmp_dir)}\nexit 0")
  end

  defp passing_harness(tmp_dir) do
    write_stub(tmp_dir, "passing", "echo \"the converged fix\" > fixed.txt\nexit 0")
  end

  defp write_stub(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "stub-#{name}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end
end

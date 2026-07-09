defmodule Kazi.SerialWorktreeIndirectionTest do
  @moduledoc """
  T50.1 (ADR-0065 decision 1, issue #937): an EXECUTING serial `kazi apply`
  runs in a kazi-owned task worktree by default; `--in-place` opts out.

  Contract:

    1. the default (worktree) path leaves the base checkout byte-identical
       (a pre-existing untracked file survives, no new files land there) while
       the run's effective workspace was a worktree that no longer exists once
       the run finishes;
    2. `--in-place` reproduces pre-T50.1 behavior: no worktree, the run edits
       the workspace directly;
    3. guard interplay (#940): `--in-place` against a primary worktree root
       still refuses; the DEFAULT path against a primary worktree root does
       NOT refuse (the worktree makes the dangerous target unreachable);
    4. cleanup fires on a non-converged terminal too (over_budget).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    :ok
  end

  test "default (no --in-place): base checkout stays byte-identical; the effective workspace was an ephemeral worktree",
       %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    untracked = Path.join(work, "untracked.txt")
    File.write!(untracked, "keep me\n")

    {status_before, 0} = System.cmd("git", ["status", "--porcelain"], cd: work)

    goal_file = write_goal_file(tmp_dir, work)

    {_out, code} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--json"],
          adapter_opts: [command: passing_harness(tmp_dir)],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)
      |> then(fn {code, out} -> {out, code} end)

    assert code == 0

    refute File.exists?(Path.join(work, "fixed.txt")),
           "the base checkout must stay untouched -- the harness's edit landed in the worktree"

    assert File.read!(untracked) == "keep me\n",
           "a pre-existing untracked file in the base checkout must survive unmodified"

    assert linked_worktrees(work) == [],
           "the worktree must be removed once the run terminates"

    {status_after, 0} = System.cmd("git", ["status", "--porcelain"], cd: work)
    assert status_after == status_before, "the base checkout's git status must be unchanged"
  end

  test "--in-place: no worktree, the run edits the workspace directly", %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work)

    {_out, code} =
      with_io(fn ->
        Kazi.CLI.run(
          [
            "apply",
            goal_file,
            "--workspace",
            work,
            "--in-place",
            "--allow-primary-workspace",
            "--json"
          ],
          adapter_opts: [command: passing_harness(tmp_dir)],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)
      |> then(fn {code, out} -> {out, code} end)

    assert code == 0
    assert File.exists?(Path.join(work, "fixed.txt")), "--in-place edits the workspace directly"
    assert linked_worktrees(work) == [], "--in-place must not create any worktree"
  end

  test "guard interplay: --in-place against a primary worktree root still refuses", %{
    tmp_dir: tmp_dir
  } do
    work = git_repo(tmp_dir)
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
    refute File.exists?(harness_called_marker(tmp_dir))
  end

  test "guard interplay: the DEFAULT path against a primary worktree root does NOT refuse", %{
    tmp_dir: tmp_dir
  } do
    work = git_repo(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work)

    {out, code} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--json"],
          adapter_opts: [command: passing_harness(tmp_dir)],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)
      |> then(fn {code, out} -> {out, code} end)

    refute out =~ "PRIMARY worktree"
    assert code == 0
  end

  test "cleanup fires on a non-converged terminal too (over_budget)", %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work, max_iterations: 1)

    {_out, code} =
      with_io(fn ->
        Kazi.CLI.run(
          ["apply", goal_file, "--workspace", work, "--json"],
          adapter_opts: [command: never_fixes_harness(tmp_dir)],
          reobserve_interval_ms: 5,
          await_timeout: 15_000
        )
      end)
      |> then(fn {code, out} -> {out, code} end)

    assert code == 1

    assert linked_worktrees(work) == [],
           "the worktree must be removed even on a non-converged (over_budget) terminal"

    {out2, 0} = System.cmd("git", ["status", "--porcelain"], cd: work)
    assert String.trim(out2) == ""
  end

  # --- fixtures -------------------------------------------------------------

  defp git_repo(tmp_dir) do
    work = Path.join(tmp_dir, "primary-#{System.unique_integer([:positive])}")
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

  # A predicate that FAILS at t0 (`test -f fixed.txt`) so the goal is never
  # vacuous, mirroring the run-registry wiring test's proven fixture shape.
  defp write_goal_file(tmp_dir, workspace, budget_opts \\ []) do
    max_iterations = Keyword.get(budget_opts, :max_iterations, 3)
    path = Path.join(tmp_dir, "swi-#{System.unique_integer([:positive])}.goal.toml")

    File.write!(path, """
    id = "serial-worktree-fixture"
    name = "serial worktree fixture"

    [scope]
    workspace = #{inspect(workspace)}

    [budget]
    max_iterations = #{max_iterations}

    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  # Every LINKED worktree still registered against `repo` (excludes the
  # primary worktree line itself) -- empty once cleanup has fully run.
  defp linked_worktrees(repo) do
    {out, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: repo)

    out
    |> String.split("\n\n", trim: true)
    |> Enum.map(&List.first(String.split(&1, "\n", trim: true)))
    |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))
    |> Enum.reject(&(Path.expand(&1) == Path.expand(repo)))
  end

  defp harness_called_marker(tmp_dir), do: Path.join(tmp_dir, "harness-called")

  defp never_called_harness(tmp_dir) do
    write_stub(tmp_dir, "never-called", "touch #{harness_called_marker(tmp_dir)}\nexit 0")
  end

  # Writes fixed.txt relative to the process's OWN cwd -- when run in a
  # worktree, the harness's cwd IS the worktree (T39.7 threading), so this
  # lands there, not the base checkout.
  defp passing_harness(tmp_dir) do
    write_stub(tmp_dir, "passing", "echo \"the converged fix\" > fixed.txt\nexit 0")
  end

  # Never writes fixed.txt, so the goal never converges -- with max_iterations
  # = 1 it terminates :over_budget.
  defp never_fixes_harness(tmp_dir) do
    write_stub(tmp_dir, "never-fixes", "exit 0")
  end

  defp write_stub(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "stub-#{name}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end
end

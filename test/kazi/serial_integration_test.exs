defmodule Kazi.SerialIntegrationTest do
  @moduledoc """
  T50.2 (ADR-0065 decision 2): a converged serial run lands its worktree work
  like a partition does — task-branch commits, rebase-merge onto the base,
  conflict → re-dispatch.

  Contract (fixture git repos in tmp, no network, no real harness — the
  fixture repos have no remote, so the default integrator resolution picks the
  LOCAL rebase-merge landing):

    1. a converged serial run whose worktree holds commits integrates them
       onto the base by rebase-merge: the base's log contains the task commits
       afterwards, and the worktree is cleaned up (and conversely: no commits
       ahead ⇒ nothing lands and the result is byte-identical, and a checkout
       that moved OFF the kazi-owned task branch owns its own landing — the
       ADR-0055 self-integrating run is not double-integrated);
    2. a conflicting base advance (a commit to the base between worktree
       creation and integration) routes through Integration's `:redispatcher`
       seam (a stub observes the call) and never force-pushes or resets the
       base — the base keeps its own advance;
    3. an integration failure surfaces in the run result (converged-but-
       unlanded is visible: `integration.landed == false`, exit 1, the
       task-branch ref reported) and the task branch still exists in the base
       repo after worktree cleanup;
    4. STRUCTURAL: the serial path's source never invokes `git reset` or
       `git clean` — neither `lib/kazi/cli.ex` nor
       `lib/kazi/scheduler/integration.ex` contains such a call site.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    :ok
  end

  test "a converged run's task-branch commits land on the base by rebase-merge",
       %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work, "test -f fixed.txt")

    {out, code} = run_apply(goal_file, work, committing_harness(tmp_dir), [])

    assert code == 0

    {log, 0} = System.cmd("git", ["log", "--oneline"], cd: work)
    assert log =~ "task commit: converged fix", "the base's log must contain the task commits"

    assert File.read!(Path.join(work, "fixed.txt")) == "the converged fix\n",
           "the fast-forwarded base checkout must hold the landed work"

    assert linked_worktrees(work) == [], "the worktree must still be cleaned up after landing"

    assert %{"status" => "converged", "integration" => integration} = Jason.decode!(out)
    assert integration["landed"] == true
    assert integration["base"] == "main"
    assert integration["refs"]["local"] == true
  end

  test "T54.1: the loop runs on the goal's REAL target branch task/<id>, not a synthetic one",
       %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    branch_file = record_file()
    goal_file = write_goal_file(tmp_dir, work, "test -f fixed.txt")

    {out, code} =
      run_apply(goal_file, work, branch_recording_harness(tmp_dir, branch_file), [])

    assert code == 0
    # The regression: before T54.1 this was `kazi-partition/p-...`, so a
    # `landed` predicate asserting `task/<id>` could NEVER pass.
    assert String.trim(File.read!(branch_file)) == "task/serial-integration-fixture",
           "the loop must execute on the goal's real target branch"

    # And it still lands (the SerialLanding discriminator recognizes it by identity).
    assert %{"integration" => integration} = Jason.decode!(out)
    assert integration["landed"] == true
    assert integration["task_branch"] == "task/serial-integration-fixture"
  end

  test "T54.1: an authored [integration] branch overrides the derived default",
       %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    branch_file = record_file()

    goal_file =
      write_goal_file(tmp_dir, work, "test -f fixed.txt",
        integration_branch: "task/custom-landing"
      )

    {out, code} =
      run_apply(goal_file, work, branch_recording_harness(tmp_dir, branch_file), [])

    assert code == 0
    assert String.trim(File.read!(branch_file)) == "task/custom-landing"

    assert %{"integration" => integration} = Jason.decode!(out)
    assert integration["landed"] == true
    assert integration["task_branch"] == "task/custom-landing"
  end

  test "a run with no commits ahead lands nothing and stays byte-identical (no integration object)",
       %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    # The T50.1 shape: the harness writes the fix but never commits — the base
    # stays untouched and the result carries no `integration` object at all.
    goal_file = write_goal_file(tmp_dir, work, "test -f fixed.txt")

    {out, code} = run_apply(goal_file, work, non_committing_harness(tmp_dir), [])

    assert code == 0
    refute File.exists?(Path.join(work, "fixed.txt"))
    refute Map.has_key?(Jason.decode!(out), "integration")
  end

  test "a run that moved off the kazi-owned task branch owns its own landing (no double-integration)",
       %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    # The ADR-0055 shape: the run's own :integrate action checks out its own
    # branch mid-run (here simulated by the harness) and lands on the remote
    # itself — the serial landing must not re-integrate that branch locally.
    goal_file = write_goal_file(tmp_dir, work, "test -f fixed.txt")

    {out, code} = run_apply(goal_file, work, own_branch_harness(tmp_dir), [])

    assert code == 0
    refute Map.has_key?(Jason.decode!(out), "integration")

    {log, 0} = System.cmd("git", ["log", "--oneline"], cd: work)
    refute log =~ "own-branch commit", "the base must not receive the off-task-branch commit"

    # The branch (and its commit) survives worktree cleanup regardless.
    {branch_log, 0} = System.cmd("git", ["log", "--oneline", "own-branch"], cd: work)
    assert branch_log =~ "own-branch commit"
  end

  test "a conflicting base advance routes through the redispatcher seam and never resets the base",
       %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    test_pid = self()

    redispatcher = fn partition ->
      send(test_pid, {:redispatched, partition})
      :converged
    end

    goal_file = write_goal_file(tmp_dir, work, "grep -q 'task version' seed.txt")

    {out, code} =
      run_apply(goal_file, work, conflicting_harness(tmp_dir, work),
        integrate: [redispatcher: redispatcher, max_attempts: 2]
      )

    # Converged in the worktree; the landing conflicted past its budget, but
    # (issue #1407) the exit code is decoupled from landing by default.
    assert code == 0
    assert_received {:redispatched, %{key: "serial-integration-fixture"}}

    assert File.read!(Path.join(work, "seed.txt")) == "base advanced\n",
           "the base's own advance must survive — never overwritten, force-pushed, or reset"

    {log, 0} = System.cmd("git", ["log", "--oneline"], cd: work)
    refute log =~ "task conflicting commit", "the conflicting task commit must not land"

    {porcelain, 0} = System.cmd("git", ["status", "--porcelain"], cd: work)
    assert String.trim(porcelain) == "", "the base working tree must be left clean"

    assert %{"integration" => integration} = Jason.decode!(out)
    assert integration["landed"] == false
    assert integration["task_branch"] == "task/serial-integration-fixture"
    assert integration["reason"] =~ "conflict"
  end

  test "an integration failure surfaces converged-but-unlanded, and the task branch survives cleanup",
       %{tmp_dir: tmp_dir} do
    work = git_repo(tmp_dir)
    goal_file = write_goal_file(tmp_dir, work, "test -f fixed.txt")

    {out, code} =
      run_apply(goal_file, work, committing_harness(tmp_dir),
        integrate: [integrator: fn _request, _opts -> {:error, :boom} end]
      )

    # (issue #1407): the exit code is decoupled from landing by default — a
    # converged-but-unlanded run still exits 0, with the failure surfaced via
    # `integration.landed == false` rather than a non-zero exit.
    assert code == 0

    assert %{"status" => "converged", "integration" => integration} = Jason.decode!(out)
    assert integration["landed"] == false
    task_branch = integration["task_branch"]
    assert task_branch == "task/serial-integration-fixture"

    assert linked_worktrees(work) == [], "the worktree is still cleaned up on landing failure"

    # The branch survives worktree removal by design — the unmerged commits are
    # never destroyed.
    {branches, 0} = System.cmd("git", ["branch", "--list", task_branch], cd: work)
    assert String.trim(branches) != "", "the task branch must survive worktree cleanup"

    {branch_log, 0} = System.cmd("git", ["log", "--oneline", task_branch], cd: work)
    assert branch_log =~ "task commit: converged fix"

    {log, 0} = System.cmd("git", ["log", "--oneline"], cd: work)
    refute log =~ "task commit: converged fix", "the unlanded commit must not be on the base"
  end

  test "STRUCTURAL: the serial path never invokes git reset/clean" do
    for file <- ["lib/kazi/cli.ex", "lib/kazi/scheduler/integration.ex"] do
      source = File.read!(file)

      refute source =~ ~r/"reset"/,
             "#{file} must not shell out to `git reset` (operator state is never kazi's to reset)"

      refute source =~ ~r/"clean"/,
             "#{file} must not shell out to `git clean` (operator state is never kazi's to clean)"
    end
  end

  # --- driving the CLI --------------------------------------------------------

  defp run_apply(goal_file, work, harness, runtime_opts) do
    with_io(fn ->
      Kazi.CLI.run(
        ["apply", goal_file, "--workspace", work, "--json"],
        Keyword.merge(
          [
            adapter_opts: [command: harness],
            reobserve_interval_ms: 5,
            await_timeout: 15_000
          ],
          runtime_opts
        )
      )
    end)
    |> then(fn {code, out} -> {out, code} end)
  end

  # --- fixtures ---------------------------------------------------------------

  defp git_repo(tmp_dir) do
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

  # A predicate that FAILS at t0 so the goal is never vacuous (the same fixture
  # shape T50.1's tests pinned). An optional `:integration_branch` authors an
  # `[integration] branch` block (T54.1) to override the derived `task/<id>`.
  defp write_goal_file(tmp_dir, workspace, predicate_cmd, opts \\ []) do
    path = Path.join(tmp_dir, "si-#{System.unique_integer([:positive])}.goal.toml")

    integration_block =
      case Keyword.get(opts, :integration_branch) do
        nil -> ""
        branch -> "\n[integration]\nbranch = #{inspect(branch)}\n"
      end

    File.write!(path, """
    id = "serial-integration-fixture"
    name = "serial integration fixture"

    [scope]
    workspace = #{inspect(workspace)}

    [budget]
    max_iterations = 3
    #{integration_block}
    [[predicate]]
    id = "code"
    provider = "custom_script"
    verdict = "exit_zero"
    cmd = "sh"
    args = ["-c", #{inspect(predicate_cmd)}]
    """)

    path
  end

  # Writes the fix AND commits it on the task branch — the run's cwd is the
  # worktree (T39.7 threading), whose git config is shared with the base repo.
  defp committing_harness(tmp_dir) do
    write_stub(tmp_dir, "committing", """
    echo "the converged fix" > fixed.txt
    git add fixed.txt
    git commit -q -m "task commit: converged fix"
    exit 0
    """)
  end

  # Records the branch the loop is ACTUALLY running on (T54.1) to an absolute
  # file the test reads, then commits the fix so the run also lands.
  # A short ABSOLUTE path for the harness to record the in-loop branch to. It
  # MUST be absolute: the harness runs with cwd = the worktree, so a relative
  # path would resolve under the (ephemeral) worktree, not where the test reads.
  defp record_file do
    Path.join(System.tmp_dir!(), "kazi-t54-branch-#{System.unique_integer([:positive])}.txt")
  end

  defp branch_recording_harness(tmp_dir, branch_file) do
    write_stub(tmp_dir, "branch-recording", """
    git rev-parse --abbrev-ref HEAD > #{branch_file}
    echo "the converged fix" > fixed.txt
    git add fixed.txt
    git commit -q -m "task commit: converged fix"
    exit 0
    """)
  end

  # Checks out its OWN branch before committing the fix — the "run owns its
  # landing" shape (a goal's own :integrate action does exactly this).
  defp own_branch_harness(tmp_dir) do
    write_stub(tmp_dir, "own-branch", """
    git checkout -q -b own-branch
    echo "the converged fix" > fixed.txt
    git add fixed.txt
    git commit -q -m "own-branch commit"
    exit 0
    """)
  end

  # Writes the fix but never commits — nothing integrable (the T50.1 shape).
  defp non_committing_harness(tmp_dir) do
    write_stub(tmp_dir, "non-committing", """
    echo "the converged fix" > fixed.txt
    exit 0
    """)
  end

  # Commits a conflicting seed.txt change on the task branch, then advances the
  # BASE with a different conflicting seed.txt commit — the "base moved between
  # worktree creation and integration" race, deterministic.
  defp conflicting_harness(tmp_dir, base) do
    write_stub(tmp_dir, "conflicting", """
    echo "task version" > seed.txt
    git add seed.txt
    git commit -q -m "task conflicting commit"
    echo "base advanced" > #{base}/seed.txt
    git -C #{base} add seed.txt
    git -C #{base} commit -q -m "base advance"
    exit 0
    """)
  end

  defp write_stub(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "stub-#{name}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end

  # Every LINKED worktree still registered against `repo` (excludes the primary
  # worktree line itself) — empty once cleanup has fully run.
  defp linked_worktrees(repo) do
    {out, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: repo)

    out
    |> String.split("\n\n", trim: true)
    |> Enum.map(&List.first(String.split(&1, "\n", trim: true)))
    |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))
    |> Enum.reject(&(Path.expand(&1) == Path.expand(repo)))
  end
end

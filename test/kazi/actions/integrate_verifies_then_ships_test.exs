defmodule Kazi.Actions.IntegrateVerifiesThenShipsTest do
  @moduledoc """
  T44.3 (ADR-0055): for `[integration]` goals (mode `commit`/`branch`/`pr`/`merge`)
  Integrate VERIFIES a clean, committed branch and ships it — it never bulk-commits.
  Real git boundary (Tier 2): actual `git` subprocesses against a local bare
  "origin", with the PR/merge seam injected as a recording integrator.

  The three behaviors this pins:

    * a clean committed branch is pushed, PR'd, and rebase-merged, with the
      converged predicate vector visible in the PR body;
    * a DIRTY tree yields the distinct `{:error, {:dirty_tree, _}}` and creates NO
      commit and NO push (the whole reason the task exists — no silent bulk commit);
    * a NO-`[integration]` goal still takes the legacy bulk-commit path unchanged
      (an uncommitted working-tree change is committed and landed).
  """
  use ExUnit.Case, async: false

  alias Kazi.{Action, Goal, PredicateResult, PredicateVector}
  alias Kazi.Actions.Integrate

  @moduletag :tmp_dir

  defp converged_vector do
    %PredicateVector{
      results: %{
        "code_green" => PredicateResult.pass(%{exit: 0}),
        :landed => PredicateResult.pass(%{mode: :commit, branch: "task/x"})
      }
    }
  end

  describe "[integration] goal — verifies then ships" do
    test "a clean committed branch is pushed, PR'd, merged, with the vector in the PR body",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      # The INNER AGENT already committed its own work on a non-base branch.
      checkout_new_branch(work, "task/x")
      File.write!(Path.join(work, "fix.txt"), "the converged fix\n")
      commit_all(work, "agent: fix the thing")

      test_pid = self()

      integrator = fn request, _opts ->
        send(test_pid, {:integrator_called, request})
        merge_commit = local_rebase_merge(bare, request.branch, request.base)
        {:ok, %{pr: 77, merge_commit: merge_commit}}
      end

      goal = Goal.new("widgets", name: "widget goal", integration: %{mode: :commit, base: "main"})
      action = Action.new(:integrate, params: %{base: "main"})

      ctx = %{workspace: work, goal: goal, vector: converged_vector(), integrator: integrator}

      assert {:ok, result} = Integrate.execute(action, ctx)
      assert result.branch == "task/x"
      assert result.pr == 77
      assert result.base == "main"

      # Pushed the agent's OWN commit (no new integrate commit created).
      {work_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: work)
      assert result.commit == String.trim(work_head)

      {pushed, 0} = System.cmd("git", ["rev-parse", "refs/heads/task/x"], cd: bare)
      assert String.trim(pushed) == result.commit

      # The PR body is the verification report carrying the converged vector.
      assert_received {:integrator_called, request}
      assert request.body =~ "verification report"
      assert request.body =~ "code_green"
      assert request.body =~ "landed"
      assert request.body =~ "rebase-merge"
      assert request.branch == "task/x"

      # It landed on the default branch.
      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
      assert tree =~ "fix.txt"
    end

    test "a DIRTY tree yields {:error, {:dirty_tree, _}} and creates NO commit and NO push",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      checkout_new_branch(work, "task/x")
      File.write!(Path.join(work, "fix.txt"), "committed fix\n")
      commit_all(work, "agent: commit the fix")
      {committed_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: work)

      # ... but the agent left an uncommitted file behind (a dirty tree).
      File.write!(Path.join(work, "stranded.txt"), "uncommitted\n")

      test_pid = self()
      integrator = fn request, _opts -> send(test_pid, {:integrator_called, request}) end

      goal = Goal.new("widgets", integration: %{mode: :commit, base: "main"})
      action = Action.new(:integrate, params: %{base: "main"})
      ctx = %{workspace: work, goal: goal, vector: converged_vector(), integrator: integrator}

      assert {:error, {:dirty_tree, paths}} = Integrate.execute(action, ctx)
      assert "stranded.txt" in paths

      # CRITICAL: nothing was committed (HEAD unchanged) and nothing was pushed.
      {head_after, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: work)
      assert String.trim(head_after) == String.trim(committed_head)

      # The stranded file is still UNTRACKED (never staged/committed).
      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: work)
      assert status =~ "?? stranded.txt"

      # The branch was never pushed to origin, and the integrator was never called.
      {branches, _} = System.cmd("git", ["branch", "--list"], cd: bare, stderr_to_stdout: true)
      refute branches =~ "task/x"
      refute_received {:integrator_called, _}
    end
  end

  describe "legacy (no [integration] block) — bulk-commit path unchanged" do
    test "an uncommitted working-tree change is committed and landed (regression pin)",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      # A converged change sitting UNCOMMITTED in the working tree — the legacy
      # model where Integrate itself commits.
      File.write!(Path.join(work, "fix.txt"), "the converged fix\n")

      integrator = fn request, _opts ->
        merge_commit = local_rebase_merge(bare, request.branch, request.base)
        {:ok, %{pr: 5, merge_commit: merge_commit}}
      end

      # A goal with the DEFAULT integration block (mode :none) must take the legacy
      # path exactly as a goal-less context would.
      goal = Goal.new("legacy-goal")
      assert goal.integration.mode == :none

      action = Action.new(:integrate, params: %{branch: "kazi/legacy-1"})
      ctx = %{workspace: work, goal: goal, integrator: integrator}

      assert {:ok, result} = Integrate.execute(action, ctx)
      assert result.branch == "kazi/legacy-1"
      assert result.pr == 5

      # The legacy path COMMITTED the uncommitted change and landed it.
      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
      assert tree =~ "fix.txt"

      {pushed, 0} = System.cmd("git", ["rev-parse", "refs/heads/kazi/legacy-1"], cd: bare)
      assert String.trim(pushed) == result.commit
    end

    test "a goal-less context is still the legacy path (byte-identical to pre-T44.3)",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)
      File.write!(Path.join(work, "fix.txt"), "no-goal fix\n")

      integrator = fn request, _opts ->
        merge_commit = local_rebase_merge(bare, request.branch, request.base)
        {:ok, %{pr: 9, merge_commit: merge_commit}}
      end

      action = Action.new(:integrate, params: %{branch: "kazi/no-goal"})
      assert {:ok, result} = Integrate.execute(action, %{workspace: work, integrator: integrator})

      assert result.branch == "kazi/no-goal"
      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
      assert tree =~ "fix.txt"
    end
  end

  # ===========================================================================
  # Fixtures (real git)
  # ===========================================================================

  defp setup_repo(tmp_dir) do
    bare = Path.join(tmp_dir, "origin.git")
    work = Path.join(tmp_dir, "work")

    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", bare])
    {_, 0} = System.cmd("git", ["clone", bare, work], stderr_to_stdout: true)
    config(work)

    File.write!(Path.join(work, "README.md"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: work)
    {_, 0} = System.cmd("git", ["push", "origin", "main"], cd: work, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: bare)

    %{bare: bare, work: work}
  end

  defp checkout_new_branch(work, branch) do
    {_, 0} = System.cmd("git", ["checkout", "-b", branch], cd: work, stderr_to_stdout: true)
  end

  defp commit_all(work, message) do
    {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
    {_, 0} = System.cmd("git", ["commit", "-m", message], cd: work, stderr_to_stdout: true)
  end

  defp local_rebase_merge(bare, branch, base) do
    tmp =
      Path.join(System.tmp_dir!(), "merge-#{System.pid()}-#{System.unique_integer([:positive])}")

    {_, 0} = System.cmd("git", ["clone", bare, tmp], stderr_to_stdout: true)
    config(tmp)

    {_, 0} = System.cmd("git", ["checkout", base], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["checkout", branch], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["rebase", base], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["checkout", base], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["merge", "--ff-only", branch], cd: tmp, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["push", "origin", base], cd: tmp, stderr_to_stdout: true)

    {sha, 0} = System.cmd("git", ["rev-parse", base], cd: tmp)
    File.rm_rf!(tmp)
    String.trim(sha)
  end

  defp config(dir) do
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: dir)
  end
end

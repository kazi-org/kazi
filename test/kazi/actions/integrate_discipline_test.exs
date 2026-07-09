defmodule Kazi.Actions.IntegrateDisciplineTest do
  # Real git boundary (Tier 2), same style as integrate_test.exs. Regression
  # coverage for issue #819: the three integrate-discipline guardrails (scoped
  # staging, CI wait before merge, informative landing artifacts).
  use ExUnit.Case, async: false

  alias Kazi.Action
  alias Kazi.Goal
  alias Kazi.PredicateResult
  alias Kazi.PredicateVector
  alias Kazi.Scope
  alias Kazi.Actions.Integrate

  @moduletag :tmp_dir

  describe "scoped staging (issue #819a)" do
    test "a goal with no declared scope paths keeps whole-workspace staging (backward compatible)",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      # An untracked file the fixer agent never touched via `[scope] paths`.
      File.write!(Path.join(work, "junk.txt"), "machine-local cruft\n")
      File.write!(Path.join(work, "fix.txt"), "the converged fix\n")

      integrator = fn request, _opts ->
        {:ok, %{pr: 1, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
      end

      action = Action.new(:integrate, params: %{branch: "kazi/no-scope"})
      ctx = %{workspace: work, integrator: integrator}

      assert {:ok, _result} = Integrate.execute(action, ctx)

      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
      assert tree =~ "fix.txt"
      assert tree =~ "junk.txt"
    end

    test "a goal with declared scope paths never stages an untracked file outside them",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      # In-scope new file (the actual fix) plus a machine-local untracked file
      # OUTSIDE the declared scope (the #816/#818 incident shape) plus a
      # modification to an already-tracked file (must still land: tracked
      # modifications are staged everywhere regardless of scope).
      File.write!(Path.join(work, "fix.txt"), "the converged fix\n")
      File.write!(Path.join(work, "junk.txt"), "machine-local cruft, never scoped\n")
      File.write!(Path.join(work, "README.md"), "seed\nmodified by the fix\n")

      integrator = fn request, _opts ->
        {:ok, %{pr: 2, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
      end

      goal = %Goal{id: "issue-819", scope: %Scope{workspace: work, paths: ["fix.txt"]}}
      action = Action.new(:integrate, params: %{branch: "kazi/scoped"})
      ctx = %{workspace: work, integrator: integrator, goal: goal}

      assert {:ok, _result} = Integrate.execute(action, ctx)

      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
      assert tree =~ "fix.txt"
      refute tree =~ "junk.txt"

      {readme, 0} = System.cmd("git", ["show", "main:README.md"], cd: bare)
      assert readme =~ "modified by the fix"
    end
  end

  describe "CI wait before merge (issue #819b)" do
    test "defaults to waiting for checks (wait_for_checks: true reaches the integrator)",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)
      File.write!(Path.join(work, "fix.txt"), "fix\n")

      test_pid = self()

      integrator = fn request, opts ->
        send(test_pid, {:opts, opts})
        {:ok, %{pr: 3, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
      end

      action = Action.new(:integrate, params: %{branch: "kazi/wait-default"})
      assert {:ok, _} = Integrate.execute(action, %{workspace: work, integrator: integrator})

      assert_received {:opts, opts}
      assert Keyword.get(opts, :wait_for_checks) == true
    end

    test "an explicit wait_for_checks: false opt-out reaches the integrator", %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)
      File.write!(Path.join(work, "fix.txt"), "fix\n")

      test_pid = self()

      integrator = fn request, opts ->
        send(test_pid, {:opts, opts})
        {:ok, %{pr: 4, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
      end

      action =
        Action.new(:integrate,
          params: %{branch: "kazi/wait-optout", wait_for_checks: false}
        )

      assert {:ok, _} = Integrate.execute(action, %{workspace: work, integrator: integrator})

      assert_received {:opts, opts}
      assert Keyword.get(opts, :wait_for_checks) == false
    end
  end

  describe "informative landing artifacts (issue #819c)" do
    test "the default commit message and PR title carry the goal id/name and converged predicates",
         %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)
      File.write!(Path.join(work, "fix.txt"), "fix\n")

      test_pid = self()

      integrator = fn request, _opts ->
        send(test_pid, {:request, request})
        {:ok, %{pr: 5, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
      end

      goal = %Goal{id: "issue-819-integrate-discipline", name: "Fix #819: integrate discipline"}

      vector =
        PredicateVector.new(%{
          integrate_discipline_regression: PredicateResult.pass(),
          integrate_docs: PredicateResult.pass(),
          suite_green: PredicateResult.fail()
        })

      action = Action.new(:integrate, params: %{branch: "kazi/msg"})
      ctx = %{workspace: work, integrator: integrator, goal: goal, vector: vector}

      assert {:ok, result} = Integrate.execute(action, ctx)

      {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%B", result.commit], cd: work)

      for text <- [log] do
        assert text =~ "issue-819-integrate-discipline"
        assert text =~ "Fix #819: integrate discipline"
        assert text =~ "integrate_discipline_regression"
        assert text =~ "integrate_docs"
      end

      # A failing predicate did not converge — it is not part of the summary.
      refute log =~ "suite_green"

      refute log =~ "land converged change"

      assert_received {:request, request}
      assert request.title =~ "issue-819-integrate-discipline"
      assert request.title =~ "integrate_discipline_regression"
      refute request.title == "land converged change"
    end

    test "with no goal/vector threaded, the default message is still non-bare", %{
      tmp_dir: tmp_dir
    } do
      %{work: work, bare: bare} = setup_repo(tmp_dir)
      File.write!(Path.join(work, "fix.txt"), "fix\n")

      integrator = fn request, _opts ->
        {:ok, %{pr: 6, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
      end

      action = Action.new(:integrate, params: %{branch: "kazi/no-goal"})
      assert {:ok, result} = Integrate.execute(action, %{workspace: work, integrator: integrator})

      {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%B", result.commit], cd: work)
      refute String.trim(log) == "land converged change"
      assert log =~ "unknown-goal"
    end
  end

  # --- fixtures ------------------------------------------------------------------

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

  defp config(repo) do
    {_, 0} = System.cmd("git", ["config", "user.email", "kazi-test@example.com"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "kazi test"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: repo)
  end

  defp local_rebase_merge(bare, branch, base) do
    # Qualify with the OS pid, not just System.unique_integer/1: that counter
    # resets per-BEAM-VM, so two concurrent `mix test` runs (e.g. sibling
    # worktrees on the same machine) can pick the identical /tmp/merge-N path
    # and one clone fails with "destination path already exists".
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
end

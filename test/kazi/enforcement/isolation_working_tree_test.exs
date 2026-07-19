defmodule Kazi.Enforcement.IsolationWorkingTreeTest do
  @moduledoc """
  H1 (deep-review 001, `docs/deep-reviews/001-full-codebase.md`): held-out
  acceptance predicates could never converge under default clean-tree isolation,
  because the isolated checker graded frozen `HEAD` — the agent's uncommitted fix
  never reached it, and the only commit path (`integrate`) is itself gated on the
  same check passing. The fix: `Kazi.Enforcement.Isolation` overlays the agent's
  candidate working-tree state (tracked edits + untracked new files) onto the
  clean worktree, then re-pins ONLY the declared `read_only_paths` (the grader's
  OWN definition files) back to `ref` — so a held-out/guard checker grades the
  candidate, while an in-iteration edit to the grader itself still cannot change
  the verdict.

  Covers, at the `Isolation` module level:

    * a tracked working-copy edit IS visible in the clean tree (candidate seen);
    * an untracked new file IS visible in the clean tree;
    * a working-copy deletion of a tracked file IS reflected (not resurrected);
    * a `read_only_paths`-declared file's working-copy tamper is NOT visible (the
      grader definition stays pinned to `ref`);
    * a `read_only_paths` path absent at `ref` has its overlay removed (absence is
      the pinned state, not an agent-authored leak);
    * graceful degradation on a non-git workspace is unchanged.

  And, end-to-end via `Kazi.Loop`, the exact H1 attack narrative: a held-out
  `:custom_script` acceptance predicate converges once the agent's UNCOMMITTED
  working copy satisfies it — reaching `:converged` before `integrate` ever runs.
  """
  use ExUnit.Case, async: true

  alias Kazi.Enforcement.Isolation
  alias Kazi.Providers.CustomScript
  alias Kazi.{Enforcement, Goal, Predicate, PredicateVector}

  # ===========================================================================
  # Module-level: overlay + grader-path pinning
  # ===========================================================================

  describe "prepare/3 — candidate overlay" do
    test "a tracked working-copy edit is visible in the clean tree" do
      dir = git_repo_with(%{"fix.txt" => "old\n"})
      File.write!(Path.join(dir, "fix.txt"), "new\n")

      {:ok, clean_path, cleanup} = Isolation.prepare(dir, "HEAD", [])
      assert File.read!(Path.join(clean_path, "fix.txt")) == "new\n"
      cleanup.()
    end

    test "an untracked new file is visible in the clean tree" do
      dir = git_repo_with(%{"a.txt" => "one\n"})
      File.write!(Path.join(dir, "b.txt"), "two\n")

      {:ok, clean_path, cleanup} = Isolation.prepare(dir, "HEAD", [])
      assert File.read!(Path.join(clean_path, "b.txt")) == "two\n"
      cleanup.()
    end

    test "a working-copy deletion of a tracked file is reflected, not resurrected" do
      dir = git_repo_with(%{"gone.txt" => "bye\n"})
      File.rm!(Path.join(dir, "gone.txt"))

      {:ok, clean_path, cleanup} = Isolation.prepare(dir, "HEAD", [])
      refute File.exists?(Path.join(clean_path, "gone.txt"))
      cleanup.()
    end
  end

  describe "prepare/3 — grader-path pinning (read_only_paths)" do
    test "a working-copy tamper of a declared grader path is NOT visible (pinned to ref)" do
      dir = git_repo_with(%{"check.sh" => "exit 0\n"})
      File.write!(Path.join(dir, "check.sh"), "exit 1\n")

      {:ok, clean_path, cleanup} = Isolation.prepare(dir, "HEAD", ["check.sh"])
      assert File.read!(Path.join(clean_path, "check.sh")) == "exit 0\n"
      cleanup.()
    end

    test "a non-declared file's tamper IS visible (only read_only_paths is pinned)" do
      dir = git_repo_with(%{"fix.txt" => "old\n", "check.sh" => "exit 0\n"})
      File.write!(Path.join(dir, "fix.txt"), "new\n")

      {:ok, clean_path, cleanup} = Isolation.prepare(dir, "HEAD", ["check.sh"])
      assert File.read!(Path.join(clean_path, "fix.txt")) == "new\n"
      cleanup.()
    end

    test "a read_only_paths file absent at ref has its overlay removed (absence is pinned)" do
      dir = git_repo_with(%{"a.txt" => "one\n"})
      File.write!(Path.join(dir, "new_grader.sh"), "exit 0\n")

      {:ok, clean_path, cleanup} = Isolation.prepare(dir, "HEAD", ["new_grader.sh"])
      refute File.exists?(Path.join(clean_path, "new_grader.sh"))
      cleanup.()
    end
  end

  test "prepare/3 degrades gracefully on a non-git workspace (unchanged)" do
    dir = tmp_dir()
    assert {:degraded, {:worktree_add_failed, _reason}} = Isolation.prepare(dir, "HEAD", [])
  end

  # ===========================================================================
  # End-to-end: the H1 attack narrative, fixed
  # ===========================================================================

  # A harness that writes the FIX unconditionally into the workspace on its first
  # run (a stand-in for "the agent applied the correct fix"), then does nothing on
  # later runs. It never commits — the fix stays in the agent's working copy,
  # exactly the H1 scenario ("the agent writes the fix in the working copy").
  defmodule FixOnceHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, workspace, opts) do
      pid = Keyword.fetch!(opts, :once_pid)

      if Agent.get_and_update(pid, fn done? -> {done?, true} end) == false do
        File.write!(Path.join(workspace, "fix.txt"), "new\n")
      end

      {:ok, %{output: "ok", cost: %{tokens: 1}}}
    end
  end

  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(_action, _context), do: {:ok, %{pr: 1}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(_action, _context), do: {:ok, %{ref: "v1"}}
  end

  test "a held-out custom_script acceptance predicate converges on the agent's uncommitted fix" do
    # `check.sh` (the grader) passes iff fix.txt contains "new" — it is the held-out
    # acceptance predicate's own checker, declared read-only (protected below).
    dir =
      git_repo_with(%{
        "fix.txt" => "old\n",
        "check.sh" => "grep -q new fix.txt\n"
      })

    {:ok, once_pid} = Agent.start_link(fn -> false end)

    gold =
      Predicate.new(:gold, :custom_script,
        acceptance?: true,
        held_out?: true,
        config: %{cmd: "sh", args: ["check.sh"], verdict: "exit_zero"}
      )

    goal = Goal.new("h1-regression", mode: :create, predicates: [gold])

    profile =
      Enforcement.new(
        enabled: true,
        clean_tree: true,
        read_only_paths: ["check.sh"]
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{custom_script: CustomScript},
        harness: FixOnceHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        workspace: dir,
        adapter_opts: [once_pid: once_pid],
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0,
        enforcement: profile
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :converged

    # The fix converged WITHOUT ever being committed — proving the held-out grader
    # graded the candidate working tree, not frozen HEAD (the H1 deadlock).
    assert {committed, 0} = System.cmd("git", ["show", "HEAD:fix.txt"], cd: dir)
    assert committed == "old\n"
  end

  # A harness that tampers check.sh ALONE (the classic "edit the grader to always
  # pass" exploit) — it never touches fix.txt, so the real condition the grader
  # checks is never actually met.
  defmodule TamperOnlyHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, workspace, opts) do
      pid = Keyword.fetch!(opts, :once_pid)

      if Agent.get_and_update(pid, fn done? -> {done?, true} end) == false do
        File.write!(Path.join(workspace, "check.sh"), "exit 0\n")
      end

      {:ok, %{output: "ok", cost: %{tokens: 1}}}
    end
  end

  test "a working-copy tamper of the held-out grader alone does NOT flip the verdict" do
    # `check.sh` is declared read-only (a grader-definition path), so its
    # working-copy tamper ("always exit 0") is pinned away by `restore_grader_paths`
    # — the checker keeps running its REAL, committed logic, which stays failing
    # because fix.txt itself was never fixed.
    dir =
      git_repo_with(%{
        "fix.txt" => "old\n",
        "check.sh" => "grep -q new fix.txt\n"
      })

    test_pid = self()
    {:ok, once_pid} = Agent.start_link(fn -> false end)

    gold =
      Predicate.new(:gold, :custom_script,
        acceptance?: true,
        held_out?: true,
        config: %{cmd: "sh", args: ["check.sh"], verdict: "exit_zero"}
      )

    goal = Goal.new("h1-tamper-regression", mode: :create, predicates: [gold])

    profile =
      Enforcement.new(
        enabled: true,
        clean_tree: true,
        read_only_paths: ["check.sh"]
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{custom_script: CustomScript},
        harness: TamperOnlyHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        workspace: dir,
        adapter_opts: [once_pid: once_pid],
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0,
        enforcement: profile,
        on_iteration: fn payload ->
          send(test_pid, {:observed, payload.iteration, payload.vector})
        end
      )

    assert_receive {:observed, 0, first}, 5_000
    assert PredicateVector.get(first, :gold).status == :fail

    # A SECOND observation, after the tampering dispatch ran — the tamper had no
    # effect: the pinned, committed grader logic still fails (fix.txt is unfixed).
    assert_receive {:observed, iteration, vector}, 5_000
    assert iteration >= 1
    assert PredicateVector.get(vector, :gold).status == :fail

    Kazi.Loop.stop(loop)
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp tmp_dir do
    dir =
      Path.join(System.tmp_dir!(), "kazi-isolation-wt-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # A real git repo seeded with the given {relative-path => contents} and one
  # commit, so HEAD is a clean tree the isolation module can check out.
  defp git_repo_with(files) do
    dir = tmp_dir()
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", dir], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: dir)

    Enum.each(files, fn {rel, contents} ->
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)

    {_, 0} = System.cmd("git", ["add", "-A"], cd: dir)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: dir, stderr_to_stdout: true)
    dir
  end
end

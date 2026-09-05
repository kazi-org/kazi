defmodule Kazi.Enforcement.IsolationEnvTest do
  @moduledoc """
  #1709 (ADR-0042 "Consequences", E71/T71.1): `Kazi.Enforcement.Isolation.prepare/3`
  always creates the clean-tree checker worktree `--detach`ed, because the goal's
  real branch is simultaneously checked out in the primary workspace and git
  refuses the same branch checked out in two worktrees at once. Inside that
  detached worktree `--abbrev-ref HEAD` returns the literal string `HEAD` and
  `@{u}` fatals (no `branch.<name>.remote` config to resolve) — so a guard or
  held-out predicate asserting branch identity or upstream tracking via either
  idiom is structurally unsatisfiable there, independent of whether the
  underlying work is correct and pushed.

  The fix: thread the goal's real branch (`Kazi.Goal.integration_branch/1`) and,
  when an `origin` remote is configured, its upstream ref as `KAZI_GOAL_BRANCH`/
  `KAZI_GOAL_UPSTREAM` into an isolated predicate's execution environment
  (`Kazi.Enforcement.Isolation.goal_env/2`), merged into the checker's env by
  `Kazi.Providers.CustomScript` alongside any goal-file-declared `:env`.

  Covers:

    * `goal_env/2` sets `KAZI_GOAL_BRANCH` to the given branch, unconditionally;
    * `goal_env/2` adds `KAZI_GOAL_UPSTREAM` as `origin/<branch>` when an `origin`
      remote is configured;
    * `goal_env/2` omits `KAZI_GOAL_UPSTREAM` when no `origin` remote exists;
    * end-to-end via `Kazi.Loop`: a guard `:custom_script` predicate reading
      `$KAZI_GOAL_BRANCH`/`$KAZI_GOAL_UPSTREAM` inside clean-tree isolation
      converges once the goal's branch is checked out, committed, and pushed
      (the exact #1709 repro, fixed);
    * a non-isolated predicate using the structurally-broken `--abbrev-ref HEAD`
      idiom is unaffected (it runs against the real workspace, unchanged).
  """
  use ExUnit.Case, async: true

  alias Kazi.Enforcement.Isolation
  alias Kazi.Providers.CustomScript
  alias Kazi.{Enforcement, Goal, Predicate}

  # ===========================================================================
  # goal_env/2 — the env-pair builder
  # ===========================================================================

  describe "goal_env/2" do
    test "sets KAZI_GOAL_BRANCH to the given branch" do
      dir = git_repo_with(%{"a.txt" => "one\n"})

      assert {"KAZI_GOAL_BRANCH", "task/my-goal"} in Isolation.goal_env(dir, "task/my-goal")
    end

    test "adds KAZI_GOAL_UPSTREAM as origin/<branch> when an origin remote is configured" do
      dir = git_repo_with(%{"a.txt" => "one\n"})

      {_, 0} =
        System.cmd("git", ["remote", "add", "origin", "https://example.invalid/r.git"], cd: dir)

      env = Isolation.goal_env(dir, "task/my-goal")
      assert {"KAZI_GOAL_BRANCH", "task/my-goal"} in env
      assert {"KAZI_GOAL_UPSTREAM", "origin/task/my-goal"} in env
    end

    test "omits KAZI_GOAL_UPSTREAM when no origin remote is configured" do
      dir = git_repo_with(%{"a.txt" => "one\n"})

      refute List.keymember?(Isolation.goal_env(dir, "task/my-goal"), "KAZI_GOAL_UPSTREAM", 0)
    end
  end

  # ===========================================================================
  # End-to-end: the #1709 repro, fixed
  # ===========================================================================

  defmodule NoopHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{output: "ok", cost: %{tokens: 1}}}
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

  test "a guard predicate reading $KAZI_GOAL_BRANCH/$KAZI_GOAL_UPSTREAM inside isolation converges (#1709)" do
    branch = "task/kg-env"
    dir = git_repo_with(%{"a.txt" => "one\n"})
    push_branch_to_origin(dir, branch)

    branch_guard =
      Predicate.new(:branch_guard, :custom_script,
        guard?: true,
        config: %{
          cmd: "sh",
          args: [
            "-c",
            ~s{[ "$KAZI_GOAL_BRANCH" = '#{branch}' ] && git rev-parse "$KAZI_GOAL_UPSTREAM" >/dev/null 2>&1}
          ],
          verdict: "exit_zero"
        }
      )

    always_pass =
      Predicate.new(:code, :custom_script, config: %{cmd: "true", verdict: "exit_zero"})

    goal = Goal.new("kg-env", predicates: [always_pass], guards: [branch_guard])

    profile = Enforcement.new(enabled: true, clean_tree: true)

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{custom_script: CustomScript},
        harness: NoopHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        workspace: dir,
        adapter_opts: [],
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0,
        enforcement: profile
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :converged
  end

  test "a non-isolated predicate using --abbrev-ref HEAD is unaffected (real workspace, unchanged)" do
    branch = "task/kg-noniso"
    dir = git_repo_with(%{"a.txt" => "one\n"})
    {_, 0} = System.cmd("git", ["checkout", "-b", branch], cd: dir, stderr_to_stdout: true)

    branch_check =
      Predicate.new(:branch_check, :custom_script,
        config: %{
          cmd: "sh",
          args: ["-c", ~s{[ "$(git rev-parse --abbrev-ref HEAD)" = '#{branch}' ]}],
          verdict: "exit_zero"
        }
      )

    goal = Goal.new("kg-noniso", predicates: [branch_check])

    # Isolation is active (some OTHER predicate would be isolated if it existed),
    # but `branch_check` itself carries no `guard?`/`held_out?`, so it is never
    # routed into the detached worktree — it evaluates against `dir`, a real
    # branch checkout, unaffected by #1709 either way.
    profile = Enforcement.new(enabled: true, clean_tree: true)

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{custom_script: CustomScript},
        harness: NoopHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        workspace: dir,
        adapter_opts: [],
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0,
        enforcement: profile
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :converged
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kazi-isolation-env-test-#{System.unique_integer([:positive])}"
      )

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

  # Checks `dir` out onto `branch`, adds a bare `origin` remote, and pushes +
  # fetches it — so `refs/remotes/origin/<branch>` genuinely resolves (shared
  # across every worktree of `dir`'s repository, including the detached one
  # `Isolation.prepare/3` creates), exactly the "checked out, committed, and
  # pushed" state #1709's fix targets.
  defp push_branch_to_origin(dir, branch) do
    bare = tmp_dir()
    File.rm_rf!(bare)
    {_, 0} = System.cmd("git", ["init", "--bare", bare], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["checkout", "-b", branch], cd: dir, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["remote", "add", "origin", bare], cd: dir, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["push", "origin", branch], cd: dir, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["fetch", "origin"], cd: dir, stderr_to_stdout: true)
    dir
  end
end

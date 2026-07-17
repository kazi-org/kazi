defmodule Kazi.Providers.LandedH1Test do
  @moduledoc """
  T44.2 (ADR-0055) × H1 (L-0024 / ADR-0042 §6): a goal that combines a HELD-OUT
  acceptance predicate (graded under clean-tree isolation) with the synthesized
  `landed` predicate (graded against the LIVE working tree) still CONVERGES — no
  deadlock. This is the interaction the task and ADR-0055 (decision 2, costs
  §"held-out-predicate deadlock class") flag as the one that must stay closed.

  Built on the same end-to-end loop fixture as
  `Kazi.Enforcement.IsolationWorkingTreeTest` (a real git repo + a scripted
  harness + `Kazi.Loop`), extended so the harness COMMITS its fix on a non-base
  branch — the state that satisfies BOTH the held-out grader (its committed logic
  passes) AND `landed` (clean tree, committed on a non-base branch). If `landed`
  were a guard/held-out predicate graded from the frozen clean ref, it would pass
  off a permanently-clean ref while the fix was stranded; because it is a visible
  working-tree predicate, it correctly gates on the real committed state and the
  vector converges only once the work has actually landed.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Providers.{CustomScript, Landed}

  # The agent's fix, applied AND committed on the current (non-base) branch on the
  # first dispatch — a stand-in for "the agent fixed the code and committed it".
  # Committing is what lets `landed` (clean tree + committed) converge alongside
  # the held-out grader.
  defmodule FixAndCommitHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, workspace, opts) do
      pid = Keyword.fetch!(opts, :once_pid)

      if Agent.get_and_update(pid, fn done? -> {done?, true} end) == false do
        File.write!(Path.join(workspace, "fix.txt"), "new\n")
        {_, 0} = System.cmd("git", ["add", "-A"], cd: workspace, stderr_to_stdout: true)
        {_, 0} = System.cmd("git", ["commit", "-m", "fix"], cd: workspace, stderr_to_stdout: true)
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

  test "held-out predicate + synthesized landed(commit) converge together" do
    dir =
      git_repo_on_branch("task/h1", %{
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

    goal =
      Goal.new("h1-landed",
        mode: :create,
        predicates: [gold],
        integration: %{mode: :commit, branch: "task/h1", base: "main"}
      )

    # Synthesize + append `landed` exactly as the loader does at load time.
    landed = Goal.landed_predicate(goal)
    assert landed.kind == :landed
    goal = %Goal{goal | predicates: goal.predicates ++ [landed]}

    profile =
      Kazi.Enforcement.new(
        enabled: true,
        clean_tree: true,
        read_only_paths: ["check.sh"]
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{custom_script: CustomScript, landed: Landed},
        harness: FixAndCommitHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        workspace: dir,
        adapter_opts: [once_pid: once_pid],
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0,
        enforcement: profile
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 10_000)
    assert result.outcome == :converged

    # The fix is genuinely landed: committed on the non-base branch, clean tree.
    assert {"new\n", 0} = System.cmd("git", ["show", "HEAD:fix.txt"], cd: dir)
    assert {out, 0} = System.cmd("git", ["status", "--porcelain"], cd: dir)
    assert String.trim(out) == ""
  end

  # A real git repo seeded with the given files + one commit on `main`, then
  # checked out onto a non-base branch (the state a landing run works from).
  defp git_repo_on_branch(branch, files) do
    dir = Path.join(System.tmp_dir!(), "kazi-landed-h1-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

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
    {_, 0} = System.cmd("git", ["checkout", "-b", branch], cd: dir, stderr_to_stdout: true)
    dir
  end
end

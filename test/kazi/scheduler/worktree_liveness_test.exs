defmodule Kazi.Scheduler.WorktreeLivenessTest do
  @moduledoc """
  T53.2 acceptance (#1022, ADR-0058): never reap a live run's worktree.

  Two halves:

    * `Kazi.Scheduler.Worktree.reap/3` consults an injected `:run_alive?`
      liveness check against the entry's recorded `run_id` (T53.2) before
      removing anything — a live owning run's worktree is SKIPPED (left in
      place, still recorded), and only reaped once that run has actually
      terminated.
    * `Kazi.Loop` detects a workspace that vanished between iterations (dir
      absent, or git's not-a-repository/deleted-cwd exit-128 signature) and
      terminates immediately with the distinct `:workspace_missing` cause
      (ADR-0058 permanence: permanent) plus a one-line remedy, instead of
      grinding iterations (or budget) against a dead path.
  """
  use ExUnit.Case, async: true

  alias Kazi.Scheduler.{Worktree, WorktreeTable}
  alias Kazi.{Action, Budget, Goal, Predicate, PredicateResult}

  # ===========================================================================
  # reap/3 liveness guard
  # ===========================================================================

  describe "Worktree.reap/3 liveness guard" do
    setup do
      repo = Path.join(System.tmp_dir!(), "kazi-wtl-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(repo)
      run!(repo, ["init", "-q"])
      run!(repo, ["config", "user.email", "test@kazi"])
      run!(repo, ["config", "user.name", "kazi test"])
      File.write!(Path.join(repo, "README.md"), "fixture\n")
      run!(repo, ["add", "."])
      run!(repo, ["commit", "-q", "-m", "init"])

      base = Path.join(System.tmp_dir!(), "kazi-wtl-base-#{System.unique_integer([:positive])}")
      worktree_path = Path.join(base, "wt")
      File.mkdir_p!(base)
      run!(repo, ["worktree", "add", "-b", "kazi-wtl-branch", worktree_path, "HEAD"])

      table_name = :"wtl_table_#{System.unique_integer([:positive])}"
      start_supervised!({WorktreeTable, name: table_name})

      on_exit(fn ->
        File.rm_rf(repo)
        File.rm_rf(base)
      end)

      %{repo: repo, worktree_path: worktree_path, table: table_name}
    end

    defp run!(repo, args) do
      {_out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    end

    test "skips reap while the owning run is live, reaps once it is terminal", ctx do
      entry = %{git_cmd: "git", repo: ctx.repo, path: ctx.worktree_path, run_id: "run-1"}
      WorktreeTable.record(:p1, entry, ctx.table)

      # The owning run is still live: reap is a no-op, the worktree survives,
      # and the entry stays recorded (so a later reap can still find it).
      assert Worktree.reap(:p1, ctx.table, run_alive?: fn "run-1" -> true end) == :ok
      assert File.dir?(ctx.worktree_path)
      assert WorktreeTable.reap(:p1, ctx.table) != nil

      # Re-record (the previous reap/2 popped it to inspect) and prove the
      # SAME entry is reaped once the owning run is reported terminal.
      WorktreeTable.record(:p1, entry, ctx.table)
      assert Worktree.reap(:p1, ctx.table, run_alive?: fn "run-1" -> false end) == :ok
      refute File.dir?(ctx.worktree_path)
    end

    test "an unset run_id behaves exactly like the pre-T53.2 unconditional reap", ctx do
      entry = %{git_cmd: "git", repo: ctx.repo, path: ctx.worktree_path, run_id: nil}
      WorktreeTable.record(:p2, entry, ctx.table)

      # No :run_alive? opt passed — defaults to "never live", so reap proceeds.
      assert Worktree.reap(:p2, ctx.table) == :ok
      refute File.dir?(ctx.worktree_path)
    end
  end

  # ===========================================================================
  # loop-level :workspace_missing terminal cause
  # ===========================================================================

  defmodule AlwaysFailProvider do
    @behaviour Kazi.PredicateProvider
    @impl true
    def evaluate(%Predicate{id: id}, _context), do: PredicateResult.fail(%{id: id})
  end

  defmodule NoopHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{output: "ok"}}
  end

  defmodule ImmediateIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule ImmediateDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  describe "Kazi.Loop workspace_missing terminal cause" do
    test "a workspace deleted between iterations terminates :workspace_missing, no further dispatch" do
      workspace =
        Path.join(System.tmp_dir!(), "kazi-wtl-ws-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)

      goal =
        Goal.new("workspace-missing-wedge",
          predicates: [Predicate.new(:code, :tests)],
          budget: Budget.new(max_iterations: 20)
        )

      # Delete the workspace out from under the loop BEFORE it ever ticks, so
      # the very first :observe hits the missing-workspace precheck instead of
      # dispatching an agent (T53.2: never grind iterations against a dead
      # path). A real gone directory — hermetic, no network, no harness.
      File.rm_rf!(workspace)

      {:ok, loop} =
        Kazi.Loop.start_link(
          goal: goal,
          providers: %{tests: AlwaysFailProvider},
          harness: NoopHarness,
          integrate: ImmediateIntegrate,
          deploy: ImmediateDeploy,
          workspace: workspace,
          reobserve_interval_ms: 1,
          check_workspace_liveness: true
        )

      assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

      assert result.outcome == :stopped
      assert result.reason == :stuck
      assert %{workspace: remedy} = result.stuck_reasons
      assert remedy =~ workspace
      assert remedy =~ "#1022"
      assert result.cause.class == :workspace_missing
      assert result.cause.reasons == result.stuck_reasons

      # No further dispatch: the loop stopped on its very first observation,
      # well short of the 20-iteration budget ceiling.
      assert result.actions == []
      assert result.iterations <= 1
    end
  end
end

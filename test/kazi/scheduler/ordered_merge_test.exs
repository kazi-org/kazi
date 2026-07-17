defmodule Kazi.Scheduler.OrderedMergeTest do
  @moduledoc """
  T44.11 (ADR-0055): `needs`-ordered merge with `git cherry` silent-revert
  verification, MERGE-mode only.

  Real git boundary (Tier 2): a fixture repo with real group branches, real
  rebase-merges, and real `git cherry` — never a mock of cherry's output. The
  diamond DAG proves the topological merge order; a deliberately LOSSY injected
  merger proves a silently-dropped hunk HALTS with both groups named; a pr-mode
  run proves no merge happens.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Group
  alias Kazi.Scheduler.OrderedMerge

  # A -> {B, C} -> D diamond: B and C both need A; D needs both B and C.
  defp diamond_goal do
    Goal.new("diamond",
      groups: [
        Group.new("a", "A"),
        Group.new("b", "B", needs: ["a"]),
        Group.new("c", "C", needs: ["a"]),
        Group.new("d", "D", needs: ["b", "c"])
      ]
    )
  end

  describe "merge_order/1" do
    test "flattens the needs-DAG frontiers into a topological merge order" do
      assert OrderedMerge.merge_order(diamond_goal()) == ["a", "b", "c", "d"]
    end
  end

  describe "merge mode — ordered rebase-merge" do
    test "a diamond DAG merges in topological order (a before b/c before d)" do
      repo = seed_repo()
      # Each group branch touches a DISJOINT file, so every rebase-merge is clean.
      for g <- ~w(a b c d), do: branch_with_file(repo, "task/#{g}", "#{g}.txt", "#{g}\n")

      test_pid = self()

      # Record the actual merge sequence, then perform the real rebase-merge.
      recording_merger = fn merge_ctx ->
        send(test_pid, {:merged, merge_ctx.group})
        real_rebase_merge(merge_ctx)
      end

      assert {:ok, result} =
               OrderedMerge.run(diamond_goal(),
                 repo: repo,
                 base: "main",
                 branch_for: &"task/#{&1}",
                 merger: recording_merger
               )

      assert result.mode == :merge
      assert result.sequence == ["a", "b", "c", "d"]

      # The ACTUAL merge order (from the recording), not just "all merged".
      assert recorded_order(4) == ["a", "b", "c", "d"]

      # Every group's file landed on the base — nothing dropped in a clean run.
      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: repo)
      for g <- ~w(a b c d), do: assert(tree =~ "#{g}.txt")
    end
  end

  describe "silent-revert verification (git cherry)" do
    test "a later merge that drops an earlier group's hunk HALTS naming both groups" do
      repo = seed_repo(%{"shared.txt" => "original\n"})

      # b and c both rewrite the SAME line, from the same base — overlapping edits.
      branch_with_file(repo, "task/b", "shared.txt", "from-b\n")
      branch_with_file(repo, "task/c", "shared.txt", "from-c\n")

      goal =
        Goal.new("overlap",
          groups: [Group.new("b", "B"), Group.new("c", "C", needs: ["b"])]
        )

      # b lands cleanly; c is landed by a LOSSY merger that force-overwrites the
      # base with c's branch (a naive "make base look like the branch" resolve),
      # silently DROPPING b's already-merged commit.
      lossy_merger = fn
        %{group: "b"} = ctx ->
          real_rebase_merge(ctx)

        %{group: "c", repo: r, base: base, branch: branch} ->
          naive_overwrite_merge(r, base, branch)
      end

      assert {:error, {:silent_revert, info}} =
               OrderedMerge.run(goal,
                 repo: repo,
                 base: "main",
                 branch_for: &"task/#{&1}",
                 merger: lossy_merger
               )

      # BOTH the lost group and the group whose merge caused the loss are named.
      assert info.lost == "b"
      assert info.caused_by == "c"
      assert info.commits != []

      # It HALTED at the revert — b's content is gone from the base (proving the
      # detection reflects reality, not a false alarm).
      {shared, 0} = System.cmd("git", ["show", "main:shared.txt"], cd: repo)
      assert shared == "from-c\n"
    end

    test "a clean diamond run passes verification (no false positives)" do
      repo = seed_repo()
      for g <- ~w(a b c d), do: branch_with_file(repo, "task/#{g}", "#{g}.txt", "#{g}\n")

      assert {:ok, %{sequence: ["a", "b", "c", "d"]}} =
               OrderedMerge.run(diamond_goal(),
                 repo: repo,
                 base: "main",
                 branch_for: &"task/#{&1}",
                 merger: &real_rebase_merge/1
               )
    end
  end

  describe "pr mode — opens PRs, merges nothing (regression pin)" do
    test "pr mode opens each group's PR in order and never advances the base" do
      repo = seed_repo()
      for g <- ~w(a b c d), do: branch_with_file(repo, "task/#{g}", "#{g}.txt", "#{g}\n")

      {base_before, 0} = System.cmd("git", ["rev-parse", "main"], cd: repo)
      test_pid = self()

      pr_opener = fn merge_ctx ->
        send(test_pid, {:pr_opened, merge_ctx.group})
        {:ok, "pr-#{merge_ctx.group}"}
      end

      assert {:ok, result} =
               OrderedMerge.run(diamond_goal(),
                 repo: repo,
                 base: "main",
                 branch_for: &"task/#{&1}",
                 mode: :pr,
                 pr_opener: pr_opener
               )

      assert result.mode == :pr
      assert result.sequence == ["a", "b", "c", "d"]
      assert result.merged == []
      assert Enum.map(result.prs, & &1.pr) == ["pr-a", "pr-b", "pr-c", "pr-d"]

      # PRs opened in topological order.
      assert recorded_pr_order(4) == ["a", "b", "c", "d"]

      # CRITICAL pin: the base branch never moved — pr-mode merges NOTHING.
      {base_after, 0} = System.cmd("git", ["rev-parse", "main"], cd: repo)
      assert base_after == base_before

      # And none of the group files reached the base.
      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: repo)
      for g <- ~w(a b c d), do: refute(tree =~ "#{g}.txt")
    end
  end

  # ===========================================================================
  # Fixtures + real git helpers
  # ===========================================================================

  defp seed_repo(files \\ %{}) do
    repo = Path.join(System.tmp_dir!(), "kazi-om-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "--initial-branch=main"])
    git!(repo, ["config", "user.email", "t@kazi"])
    git!(repo, ["config", "user.name", "kazi"])
    git!(repo, ["config", "commit.gpgsign", "false"])

    File.write!(Path.join(repo, "README.md"), "seed\n")
    Enum.each(files, fn {rel, contents} -> File.write!(Path.join(repo, rel), contents) end)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-qm", "seed"])

    on_exit(fn -> File.rm_rf(repo) end)
    repo
  end

  # Create `branch` off main with one commit writing `contents` to `file`, then
  # return to main.
  defp branch_with_file(repo, branch, file, contents) do
    git!(repo, ["checkout", "-q", "-b", branch, "main"])
    File.write!(Path.join(repo, file), contents)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-qm", "#{branch}: #{file}"])
    git!(repo, ["checkout", "-q", "main"])
  end

  # A real local rebase-merge of the group branch onto the base (the house rule).
  defp real_rebase_merge(%{repo: repo, base: base, branch: branch}) do
    git!(repo, ["checkout", "-q", branch])
    git!(repo, ["rebase", "-q", base])
    git!(repo, ["checkout", "-q", base])
    git!(repo, ["merge", "--ff-only", "-q", branch])
    {sha, 0} = System.cmd("git", ["rev-parse", base], cd: repo)
    {:ok, String.trim(sha)}
  end

  # A deliberately LOSSY merge: force-overwrite the base with the incoming branch
  # (a naive "make base look like the branch" resolve). This DROPS every commit
  # already on the base but not on the branch — exactly the silently-lost work the
  # `git cherry` check must catch (the dropped commit has no patch-equivalent on
  # the rewritten base).
  defp naive_overwrite_merge(repo, base, branch) do
    git!(repo, ["checkout", "-q", base])
    git!(repo, ["reset", "--hard", "-q", branch])
    {sha, 0} = System.cmd("git", ["rev-parse", base], cd: repo)
    {:ok, String.trim(sha)}
  end

  defp recorded_order(n),
    do:
      for(
        _ <- 1..n,
        do:
          receive do
            {:merged, g} -> g
          end
      )

  defp recorded_pr_order(n),
    do:
      for(
        _ <- 1..n,
        do:
          receive do
            {:pr_opened, g} -> g
          end
      )

  defp git!(repo, args) do
    {_out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    :ok
  end
end

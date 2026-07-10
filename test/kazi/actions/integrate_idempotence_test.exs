defmodule Kazi.Actions.IntegrateIdempotenceTest do
  @moduledoc """
  T53.1 (issue #1027): `Kazi.Actions.Integrate` must be a no-op when the
  workspace is ALREADY landed -- clean tree, current branch has an upstream,
  and HEAD == @{u} -- instead of minting a fresh `kazi/integrate-<ts>` branch
  on every invocation. Two real failure modes motivate this: a `landed`
  predicate pinned to HEAD==@{u} looping forever, and -- worse -- a `landed`
  predicate checking "whatever branch HEAD is on" silently passing against the
  substituted integrate branch while the named task branch has zero commits.
  """
  use ExUnit.Case, async: false

  alias Kazi.Action
  alias Kazi.Actions.Integrate

  @moduletag :tmp_dir

  describe "idempotence (issue #1027)" do
    test "dirty work: integrate behaves as today -- mints and pushes a branch", %{
      tmp_dir: tmp_dir
    } do
      %{work: work, bare: bare} = setup_repo(tmp_dir)
      File.write!(Path.join(work, "fix.txt"), "the converged fix\n")

      integrator = fn request, _opts ->
        merge_commit = local_rebase_merge(bare, request.branch, request.base)
        {:ok, %{pr: 1, merge_commit: merge_commit}}
      end

      assert {:ok, result} =
               Integrate.execute(Action.new(:integrate, params: %{branch: "kazi/fix-1"}), %{
                 workspace: work,
                 integrator: integrator
               })

      refute result[:already_landed]
      assert result.branch == "kazi/fix-1"

      {branches, 0} = System.cmd("git", ["branch", "--list", "kazi/fix-1"], cd: work)
      assert branches =~ "kazi/fix-1"
    end

    test "idempotence: a second integrate on a clean, pushed, current workspace is a no-op", %{
      tmp_dir: tmp_dir
    } do
      %{work: work, bare: bare} = setup_repo(tmp_dir)
      File.write!(Path.join(work, "fix.txt"), "the converged fix\n")

      integrator = fn request, _opts ->
        merge_commit = local_rebase_merge(bare, request.branch, request.base)
        {:ok, %{pr: 1, merge_commit: merge_commit}}
      end

      assert {:ok, _first} =
               Integrate.execute(Action.new(:integrate, params: %{branch: "kazi/fix-2"}), %{
                 workspace: work,
                 integrator: integrator
               })

      # Bring `work` to the state a serial task worktree or a re-observed goal
      # actually arrives in after landing: clean, on main, current with origin.
      {_, 0} = System.cmd("git", ["checkout", "main"], cd: work, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["pull", "origin", "main"], cd: work, stderr_to_stdout: true)

      refs_before = refs(work)
      {head_before, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: work)

      integrator_not_called = fn _request, _opts ->
        flunk("integrator must not be called on an idempotent no-op")
      end

      assert {:ok, second} =
               Integrate.execute(Action.new(:integrate, params: %{branch: "kazi/fix-2"}), %{
                 workspace: work,
                 integrator: integrator_not_called
               })

      assert second.already_landed

      assert refs(work) == refs_before, "no new branch must be created"

      {head_after, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: work)
      assert head_after == head_before, "HEAD must not move"
    end

    test "already on a pushed-and-current task branch: succeeds without moving HEAD or creating a ref",
         %{tmp_dir: tmp_dir} do
      %{work: work} = setup_repo(tmp_dir)

      {_, 0} = System.cmd("git", ["checkout", "-b", "task/x"], cd: work, stderr_to_stdout: true)
      File.write!(Path.join(work, "task.txt"), "already landed on task/x\n")
      {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
      {_, 0} = System.cmd("git", ["commit", "-m", "task work"], cd: work, stderr_to_stdout: true)

      {_, 0} =
        System.cmd("git", ["push", "--set-upstream", "origin", "task/x"],
          cd: work,
          stderr_to_stdout: true
        )

      refs_before = refs(work)
      {head_before, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: work)
      {branch_before, 0} = System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: work)

      integrator_not_called = fn _request, _opts ->
        flunk("integrator must not be called on an idempotent no-op")
      end

      assert {:ok, result} =
               Integrate.execute(Action.new(:integrate), %{
                 workspace: work,
                 integrator: integrator_not_called
               })

      assert result.already_landed
      assert result.branch == String.trim(branch_before)

      {head_after, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: work)
      assert head_after == head_before
      assert refs(work) == refs_before
    end

    test "a clean tree WITHOUT an upstream still lands (no false no-op)", %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: work)

      {_, 0} =
        System.cmd("git", ["checkout", String.trim(head)], cd: work, stderr_to_stdout: true)

      integrator = fn request, _opts ->
        merge_commit = local_rebase_merge(bare, request.branch, request.base)
        {:ok, %{pr: 1, merge_commit: merge_commit}}
      end

      assert {:ok, result} =
               Integrate.execute(
                 Action.new(:integrate, params: %{branch: "kazi/no-upstream"}),
                 %{workspace: work, integrator: integrator}
               )

      refute result[:already_landed]
      assert result.branch == "kazi/no-upstream"
    end
  end

  # --- fixtures ------------------------------------------------------------------

  # A local bare "origin" with an initial commit on `main`, plus a working clone.
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

  # Stand-in for `gh pr merge --rebase`: rebase the pushed branch onto base
  # inside a fresh clone of the bare origin and push the result to base.
  # Returns the new tip SHA of base.
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

  # All local branch refs, sorted -- used to assert no new ref was created.
  defp refs(repo) do
    {out, 0} =
      System.cmd("git", ["for-each-ref", "--format=%(refname)", "refs/heads/"], cd: repo)

    out |> String.split("\n", trim: true) |> Enum.sort()
  end
end

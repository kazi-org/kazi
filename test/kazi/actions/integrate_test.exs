defmodule Kazi.Actions.IntegrateTest do
  # Real git boundary (Tier 2): exercises actual `git` subprocesses against a
  # local bare "origin". Not async — each test owns a temp dir but git's global
  # config / process env is shared.
  use ExUnit.Case, async: false

  alias Kazi.Action
  alias Kazi.Actions.Integrate

  @moduletag :tmp_dir

  describe "execute/2 (real local git, injected PR/merge seam)" do
    test "lands a converged change on the default branch", %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)

      # A converged change sitting in the working tree.
      File.write!(Path.join(work, "fix.txt"), "the converged fix\n")

      # Recording integrator that performs a REAL local rebase-merge into the bare
      # origin (standing in for `gh pr merge --rebase`) and records its args.
      test_pid = self()

      integrator = fn request, _opts ->
        send(test_pid, {:integrator_called, request})
        merge_commit = local_rebase_merge(bare, request.branch, request.base)
        {:ok, %{pr: 4242, merge_commit: merge_commit}}
      end

      action = Action.new(:integrate, params: %{branch: "kazi/fix-1"})
      ctx = %{workspace: work, integrator: integrator}

      assert {:ok, result} = Integrate.execute(action, ctx)

      # Result carries useful refs.
      assert result.branch == "kazi/fix-1"
      assert result.pr == 4242
      assert result.base == "main"
      assert is_binary(result.commit) and byte_size(result.commit) == 40
      assert is_binary(result.merge_commit)

      # The integrator (PR/merge seam) was invoked with the right args.
      assert_received {:integrator_called, request}
      assert request.branch == "kazi/fix-1"
      assert request.base == "main"
      assert request.workspace == work
      assert is_binary(request.title)
      assert is_binary(request.body)

      # The branch was created and the commit pushed to origin.
      {branches, 0} = System.cmd("git", ["branch", "--list", "kazi/fix-1"], cd: work)
      assert branches =~ "kazi/fix-1"

      {pushed, 0} =
        System.cmd("git", ["rev-parse", "refs/heads/kazi/fix-1"],
          cd: bare,
          stderr_to_stdout: true
        )

      assert String.trim(pushed) == result.commit

      # The change actually landed on the default branch of origin.
      {default_tip, 0} = System.cmd("git", ["rev-parse", "refs/heads/main"], cd: bare)
      assert String.trim(default_tip) == result.merge_commit

      {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
      assert tree =~ "fix.txt"
    end

    test "uses defaults for branch/base/message when params omitted", %{tmp_dir: tmp_dir} do
      %{work: work, bare: bare} = setup_repo(tmp_dir)
      File.write!(Path.join(work, "fix.txt"), "default-path fix\n")

      integrator = fn request, _opts ->
        merge_commit = local_rebase_merge(bare, request.branch, request.base)
        {:ok, %{pr: 1, merge_commit: merge_commit}}
      end

      assert {:ok, result} =
               Integrate.execute(Action.new(:integrate), %{
                 workspace: work,
                 integrator: integrator
               })

      assert result.base == "main"
      assert String.starts_with?(result.branch, "kazi/integrate-")
    end

    test "returns an error (not an exception) when push is rejected", %{tmp_dir: tmp_dir} do
      %{work: work} = setup_repo(tmp_dir)
      File.write!(Path.join(work, "fix.txt"), "doomed fix\n")

      # Point origin at a path that is not a valid git repo so `git push` fails.
      bogus = Path.join(tmp_dir, "not-a-repo")
      File.mkdir_p!(bogus)
      {_, 0} = System.cmd("git", ["remote", "set-url", "origin", bogus], cd: work)

      integrator = fn _request, _opts ->
        flunk("integrator must not be called when push fails")
      end

      assert {:error, {:push_failed, reason}} =
               Integrate.execute(Action.new(:integrate, params: %{branch: "kazi/doomed"}), %{
                 workspace: work,
                 integrator: integrator
               })

      assert is_binary(reason)
    end

    test "returns an error when no workspace is provided" do
      assert {:error, :missing_workspace} =
               Integrate.execute(Action.new(:integrate), %{})
    end

    test "an integrator error propagates as the action result", %{tmp_dir: tmp_dir} do
      %{work: work} = setup_repo(tmp_dir)
      File.write!(Path.join(work, "fix.txt"), "fix\n")

      integrator = fn _request, _opts -> {:error, :pr_create_failed} end

      assert {:error, :pr_create_failed} =
               Integrate.execute(Action.new(:integrate, params: %{branch: "kazi/x"}), %{
                 workspace: work,
                 integrator: integrator
               })
    end

    test "rejects an unsupported action kind" do
      assert {:error, {:unsupported_kind, :deploy}} =
               Integrate.execute(Action.new(:deploy), %{workspace: "/tmp"})
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

  # Stand-in for `gh pr merge --rebase`: rebase the pushed branch onto base inside
  # a fresh clone of the bare origin and push the result to base. Returns the new
  # tip SHA of base. Proves the change reaches the default branch via rebase.
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

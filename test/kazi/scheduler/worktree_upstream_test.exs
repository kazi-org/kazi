defmodule Kazi.Scheduler.WorktreeUpstreamTest do
  @moduledoc """
  T54.3 (issue #1075): the run-owned partition branch must be pushed WITH
  upstream ONCE at worktree creation when the base repo has an `origin`, so an
  in-loop `landed` predicate gated on `@{u}` RESOLVES instead of hard-failing
  `no upstream configured for branch '<owned-branch>'` on every iteration — the
  deadlock where landing (the only push) never happens because convergence needs
  the `@{u}`-gated `landed` to pass first.

  Real boundary: an actual local BARE repo as `origin`, the real `git` binary,
  no network, no harness — the create-time push is exercised end-to-end.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kazi.Action
  alias Kazi.Actions.Integrate
  alias Kazi.Scheduler.Worktree

  setup do
    root = Path.join(System.tmp_dir!(), "kazi-wt-up-#{System.unique_integer([:positive])}")
    bare = Path.join(root, "origin.git")
    repo = Path.join(root, "repo")
    base = Path.join(root, "base")
    File.mkdir_p!(repo)

    run!(bare_parent(bare), ["init", "--bare", "--initial-branch=main", bare])

    run!(repo, ["init", "-q", "--initial-branch=main"])
    run!(repo, ["config", "user.email", "test@kazi"])
    run!(repo, ["config", "user.name", "kazi test"])
    run!(repo, ["config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "fixture\n")
    run!(repo, ["add", "."])
    run!(repo, ["commit", "-q", "-m", "init"])
    run!(repo, ["remote", "add", "origin", bare])
    run!(repo, ["push", "-q", "-u", "origin", "main"])

    on_exit(fn -> File.rm_rf(root) end)

    %{repo: repo, base: base, bare: bare}
  end

  defp bare_parent(bare) do
    parent = Path.dirname(bare)
    File.mkdir_p!(parent)
    parent
  end

  defp run!(cwd, args) do
    {_out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
  end

  defp partition(key), do: %{key: key}

  # Mirror the goal's `landed` predicate exactly: clean tree, an upstream is set,
  # and HEAD == @{u} (partition-safe, no hardcoded branch name).
  defp landed?(path) do
    with {clean, 0} <- System.cmd("git", ["status", "--porcelain"], cd: path),
         "" <- String.trim(clean),
         {_u, 0} <- System.cmd("git", ["rev-parse", "--abbrev-ref", "@{u}"], cd: path),
         {head, 0} <- System.cmd("git", ["rev-parse", "HEAD"], cd: path),
         {upstream, 0} <- System.cmd("git", ["rev-parse", "@{u}"], cd: path) do
      String.trim(head) == String.trim(upstream)
    else
      _ -> false
    end
  end

  describe "create-time upstream push (issue #1075)" do
    test "an in-loop @{u} check RESOLVES with no manual push", ctx do
      test_pid = self()

      inner = fn _partition, path ->
        # This is the crux: BEFORE the fix `git rev-parse @{u}` fails with
        # `no upstream configured` here, so a `landed`/`@{u}` predicate can never
        # pass and the loop deadlocks. AFTER the fix the branch was pushed with
        # upstream at creation, so @{u} resolves and `landed` passes.
        {u_out, u_status} =
          System.cmd("git", ["rev-parse", "--abbrev-ref", "@{u}"],
            cd: path,
            stderr_to_stdout: true
          )

        send(test_pid, {:upstream, u_status, String.trim(u_out), landed?(path)})
        :converged
      end

      reconciler = Worktree.wrap(inner, repo: ctx.repo, base_dir: ctx.base)
      assert reconciler.(partition("k1")) == :converged

      assert_received {:upstream, status, upstream_ref, landed}
      assert status == 0, "the owned branch must have an upstream after creation"
      assert upstream_ref =~ ~r{^origin/kazi-partition/}
      assert landed, "a landed predicate gated on @{u} must pass with no manual push"

      # The owned branch really exists on the bare origin.
      {remote_branches, 0} = System.cmd("git", ["branch", "--list"], cd: ctx.bare)
      assert remote_branches =~ "kazi-partition/"
    end

    test "no `origin` configured: the create-time push is a silent no-op", ctx do
      # A local-only repo (no remote) must still run the partition; the push is
      # gated on an `origin` existing so the pre-existing T21.4 suite is unaffected.
      run!(ctx.repo, ["remote", "remove", "origin"])
      test_pid = self()

      inner = fn _partition, path ->
        {_u, status} =
          System.cmd("git", ["rev-parse", "@{u}"], cd: path, stderr_to_stdout: true)

        send(test_pid, {:no_upstream, status})
        :converged
      end

      reconciler = Worktree.wrap(inner, repo: ctx.repo, base_dir: ctx.base)
      assert reconciler.(partition("k2")) == :converged
      # No origin, so no upstream was set — and no crash.
      assert_received {:no_upstream, status}
      assert status != 0
    end

    test "an unreachable origin is logged, not fatal — the partition still runs", ctx do
      run!(ctx.repo, ["remote", "set-url", "origin", Path.join(ctx.repo, "does-not-exist.git")])

      inner = fn _partition, _path -> :stuck end
      reconciler = Worktree.wrap(inner, repo: ctx.repo, base_dir: ctx.base)

      log =
        capture_log(fn ->
          assert reconciler.(partition("k3")) == :stuck
        end)

      assert log =~ "could not push owned branch"
    end
  end

  describe "does not trip already_landed/1 into a spurious no-op (issue #1027 interaction)" do
    test "after the create-time push, a worktree with NEW committed work still lands", ctx do
      test_pid = self()

      inner = fn _partition, path ->
        # The loop's real work: a genuine commit on the owned branch. HEAD now
        # moves AHEAD of the create-time @{u}, so integrate must NOT treat the
        # workspace as already-landed (that would be the spurious no-op #1075
        # warns against).
        File.write!(Path.join(path, "fix.txt"), "the converged fix\n")
        run!(path, ["add", "-A"])
        run!(path, ["commit", "-q", "-m", "loop work"])

        integrator = fn _request, _opts ->
          send(test_pid, :integrator_called)
          {:ok, %{pr: 7, merge_commit: "deadbeef"}}
        end

        result =
          Integrate.execute(Action.new(:integrate, params: %{branch: "kazi/land-1"}), %{
            workspace: path,
            integrator: integrator
          })

        send(test_pid, {:integrate, result})
        :converged
      end

      reconciler = Worktree.wrap(inner, repo: ctx.repo, base_dir: ctx.base)
      assert reconciler.(partition("work")) == :converged

      assert_received :integrator_called
      assert_received {:integrate, {:ok, result}}
      refute result[:already_landed], "committed loop work must not read as already-landed"
    end
  end
end

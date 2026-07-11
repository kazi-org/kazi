defmodule Kazi.Scheduler.WorktreeTeardownTest do
  @moduledoc """
  issue #1053: a fleet member that COMPLETED its work and THEN crashed during
  task-worktree teardown (`:enoent` spawning `git` in `safe_cleanup/3`) must
  not be reported as a crash, and teardown must never be able to touch a path
  outside the managed base dir — regardless of which path the caller (or a
  base-vs-member mix-up) hands it.

  Hermetic: a real but throwaway git repo under a temp dir, an injected
  (possibly broken) `:git_cmd`, no network, no real harness.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kazi.Scheduler.Worktree

  setup do
    repo = Path.join(System.tmp_dir!(), "kazi-wtd-repo-#{System.unique_integer([:positive])}")
    base = Path.join(System.tmp_dir!(), "kazi-wtd-base-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)

    run!(repo, ["init", "-q"])
    run!(repo, ["config", "user.email", "test@kazi"])
    run!(repo, ["config", "user.name", "kazi test"])
    File.write!(Path.join(repo, "README.md"), "fixture\n")
    run!(repo, ["add", "."])
    run!(repo, ["commit", "-q", "-m", "init"])

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm_rf(base)
    end)

    %{repo: repo, base: base}
  end

  defp run!(repo, args) do
    {_out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
  end

  defp partition(key), do: %{key: key}

  # A `git_cmd` that WORKS for worktree creation but then vanishes (mirroring
  # #1053's `:enoent` from `:erlang.open_port`) once the inner reconciler has
  # already returned — a copy of the real `git` binary the inner reconciler
  # deletes itself, so `System.cmd/3` raises `:enoent` ONLY when teardown
  # tries to invoke it, not before.
  defp vanishing_git!(base) do
    # NOT named `git-<suffix>`: git dispatches an argv0 of that shape as its
    # OWN subcommand shim ("cannot handle <suffix> as a builtin") rather than
    # running it as plain git.
    real_git = System.find_executable("git")
    link = Path.join(base, "kazigit#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    File.ln_s!(real_git, link)
    link
  end

  describe "sub-fix (1): teardown independence" do
    test "a converged member stays converged even when teardown itself raises", ctx do
      git_cmd = vanishing_git!(ctx.base)

      inner = fn _partition, _path ->
        File.rm!(git_cmd)
        :converged
      end

      reconciler = Worktree.wrap(inner, repo: ctx.repo, base_dir: ctx.base, git_cmd: git_cmd)

      log =
        capture_log(fn ->
          assert reconciler.(partition("landed")) == :converged
        end)

      assert log =~ "teardown crashed"
    end

    test "a full member map (fleet shape) still round-trips through a teardown crash", ctx do
      git_cmd = vanishing_git!(ctx.base)
      member = %{status: :converged, economy: nil, workspace: "/tmp/x", integration: %{}}

      inner = fn _partition, _path ->
        File.rm!(git_cmd)
        member
      end

      reconciler = Worktree.wrap(inner, repo: ctx.repo, base_dir: ctx.base, git_cmd: git_cmd)

      capture_log(fn ->
        assert reconciler.(partition("landed-2")) == member
      end)
    end

    test "a genuine crash from the inner is still a crash (unaffected)", ctx do
      inner = fn _partition, _path -> raise "kaboom" end
      reconciler = Worktree.wrap(inner, repo: ctx.repo, base_dir: ctx.base)

      capture_log(fn ->
        assert_raise RuntimeError, "kaboom", fn -> reconciler.(partition("boom")) end
      end)
    end
  end

  describe "sub-fix (0): base protection" do
    test "a normal member worktree IS a managed path", ctx do
      assert Worktree.managed_path?(Path.join(ctx.base, "p-a-1"), ctx.base, ctx.repo)
    end

    test "the base/repo itself is NEVER a managed path", ctx do
      refute Worktree.managed_path?(ctx.repo, ctx.base, ctx.repo)
    end

    test "a path outside the managed base dir is never a managed path", ctx do
      refute Worktree.managed_path?(ctx.repo, ctx.base, ctx.repo)
      refute Worktree.managed_path?(System.tmp_dir!(), ctx.base, ctx.repo)
    end
  end
end

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
  # already returned — a wrapper the inner reconciler deletes itself, so
  # `System.cmd/3` raises `:enoent` ONLY when teardown tries to invoke it,
  # not before.
  #
  # A real, executable WRAPPER SCRIPT that execs the real git binary — NOT a
  # symlink to it (issue #1136). A symlink under a throwaway basename breaks
  # deterministically on a host where `git` resolves to Apple's Xcode/Command
  # Line Tools binary (`/usr/bin/git`): that binary dispatches on argv[0]'s
  # basename the way `xcrun`-provided toolchain proxies do, and for a name it
  # doesn't recognize it shells out to `xcodebuild -find <name>` and fails —
  # exit 72, "xcode-select: Failed to locate '<name>'" — never running git at
  # all, so worktree creation's `rev-parse` fails BEFORE the inner reconciler
  # even runs. A wrapper script's own basename is irrelevant to the git it
  # execs (its argv[0] is the literal `git` in the script body below), so
  # this runs identically regardless of which git binary the host provides.
  # (NOT named `git-<suffix>` either: plain git itself dispatches an argv0 of
  # that shape as its own subcommand shim -- moot here since the wrapper's
  # name is never passed to git as argv0, but kept nonce-shaped regardless.)
  defp vanishing_git!(base) do
    real_git = System.find_executable("git")
    link = Path.join(base, "kazigit#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    File.write!(link, "#!/bin/sh\nexec #{real_git} \"$@\"\n")
    File.chmod!(link, 0o755)
    link
  end

  describe "sub-fix (1): teardown independence" do
    test "the vanishing_git! fixture runs real git regardless of argv0 dispatch (#1136)",
         ctx do
      # Pins the actual #1136 root cause directly: the fixture executable,
      # invoked under its own throwaway basename (never "git"), must still
      # behave as real git. A `File.ln_s!` symlink to the executable failed
      # this on a host where `git` resolves to Apple's Xcode/Command Line
      # Tools binary (it dispatches on argv[0]'s basename and, for a name it
      # doesn't recognize, shells out to `xcodebuild -find <name>` instead of
      # running git) -- silently breaking worktree creation itself, before
      # either "teardown independence" test below ever reached teardown.
      git_cmd = vanishing_git!(ctx.base)

      {out, status} =
        System.cmd(git_cmd, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
          cd: ctx.repo,
          stderr_to_stdout: true
        )

      assert status == 0
      assert String.trim(out) != ""
    end

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

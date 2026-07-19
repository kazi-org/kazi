defmodule Kazi.Scheduler.WorktreeTest do
  @moduledoc """
  T21.4 acceptance (ADR-0027; concept §9) on a FIXTURE git repo: N partitions each
  get a distinct worktree path created on start + removed on terminal; a crashed
  partition still has its worktree cleaned; the worktree guard is honored (no
  cwd-rm).

  Hermetic: a real but throwaway git repo under a temp dir, the real `git`
  binary, and an injected inner reconciler — no network, no harness.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kazi.Scheduler.Worktree

  setup do
    repo = Path.join(System.tmp_dir!(), "kazi-wt-repo-#{System.unique_integer([:positive])}")
    base = Path.join(System.tmp_dir!(), "kazi-wt-base-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)

    # A minimal git repo with one commit so `HEAD` exists for `worktree add`.
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

  defp listed_worktrees(repo) do
    {out, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: repo)

    out
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "worktree "))
    |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))
  end

  # git reports canonical (realpath) paths; on macOS /var is a symlink to
  # /private/var, so compare resolved paths, not raw strings.
  defp canonical(path), do: path |> Path.expand() |> resolve()

  defp resolve(path) do
    case File.read_link(path) do
      {:ok, _} -> path
      _ -> if File.exists?(path), do: realpath(path), else: path
    end
  end

  defp realpath(path) do
    {out, 0} = System.cmd("/bin/sh", ["-c", "cd #{path} && pwd -P"])
    String.trim(out)
  end

  defp only_repo_listed?(repo) do
    listed = Enum.map(listed_worktrees(repo), &Path.expand/1)
    listed == [canonical(repo)] or listed == [Path.expand(repo)]
  end

  describe "create on start / remove on terminal" do
    test "the worktree exists DURING the run and is gone AFTER it", ctx do
      test_pid = self()

      inner = fn _partition, path ->
        # The worktree dir exists mid-run, is a real checkout (has README), and
        # lives under the managed base dir (NOT inside the repo).
        send(
          test_pid,
          {:path, path, File.dir?(path), File.regular?(Path.join(path, "README.md"))}
        )

        :converged
      end

      reconciler = Worktree.wrap(inner, repo: ctx.repo, base_dir: ctx.base)

      assert reconciler.(partition("k1")) == :converged

      assert_received {:path, path, true, true}
      assert String.starts_with?(Path.expand(path), Path.expand(ctx.base))
      # Removed on terminal: the dir is gone and git no longer lists it.
      refute File.dir?(path)
      refute path in listed_worktrees(ctx.repo)
    end

    test "N partitions each get a DISTINCT worktree path", ctx do
      test_pid = self()

      inner = fn partition, path ->
        send(test_pid, {:wt, partition.key, path})
        :converged
      end

      reconciler = Worktree.wrap(inner, repo: ctx.repo, base_dir: ctx.base)

      keys = ["a", "b", "c", "d"]

      tasks = Enum.map(keys, fn k -> Task.async(fn -> reconciler.(partition(k)) end) end)
      assert Enum.all?(Task.await_many(tasks), &(&1 == :converged))

      paths =
        for _ <- keys do
          assert_receive {:wt, _key, path}
          path
        end

      # All N paths are distinct (no two partitions shared a worktree).
      assert paths |> Enum.uniq() |> length() == length(keys)
      # All cleaned up afterward.
      assert Enum.all?(paths, &(not File.dir?(&1)))
      assert only_repo_listed?(ctx.repo)
    end

    test "T54.1: :owned_branch checks the worktree out onto exactly that branch", ctx do
      test_pid = self()

      inner = fn _partition, path ->
        {branch, 0} =
          System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], cd: path)

        send(test_pid, {:branch, String.trim(branch), path})
        :converged
      end

      reconciler =
        Worktree.wrap(inner, repo: ctx.repo, base_dir: ctx.base, owned_branch: "task/widgets")

      assert reconciler.(partition("k1")) == :converged
      assert_received {:branch, "task/widgets", _path}
    end

    test "T54.1: a stable :owned_branch is idempotent across re-runs (-B create-or-reset)", ctx do
      inner = fn _partition, _path -> :converged end

      reconciler =
        Worktree.wrap(inner, repo: ctx.repo, base_dir: ctx.base, owned_branch: "task/rerun")

      # A prior run created and cleaned up its worktree, leaving the branch behind.
      assert reconciler.(partition("k1")) == :converged
      # A second run reuses the same owned branch name — `-b` would fail here;
      # `-B` resets it off the base and succeeds.
      assert reconciler.(partition("k1")) == :converged
      assert only_repo_listed?(ctx.repo)
    end
  end

  describe "cleanup on crash (terminal incl. crash)" do
    test "a crashed partition still has its worktree removed", ctx do
      test_pid = self()

      inner = fn _partition, path ->
        send(test_pid, {:crash_path, path})
        raise "kaboom"
      end

      reconciler = Worktree.wrap(inner, repo: ctx.repo, base_dir: ctx.base)

      capture_log(fn ->
        assert_raise RuntimeError, "kaboom", fn -> reconciler.(partition("boom")) end
      end)

      assert_received {:crash_path, path}
      # The `after` ran during unwind — the worktree is gone despite the crash.
      refute File.dir?(path)
      assert only_repo_listed?(ctx.repo)
    end

    test "a dirty worktree (uncommitted edits) is still force-removed on terminal", ctx do
      inner = fn _partition, path ->
        # Leave the worktree dirty; `--force` must still remove it.
        File.write!(Path.join(path, "dirty.txt"), "uncommitted\n")
        :stuck
      end

      reconciler = Worktree.wrap(inner, repo: ctx.repo, base_dir: ctx.base)

      assert reconciler.(partition("dirty")) == :stuck
      assert only_repo_listed?(ctx.repo)
    end
  end

  describe "the worktree guard is honored (never rm a cwd/repo)" do
    test "safe_cleanup REFUSES to rm the repo itself even if git remove fails", ctx do
      # If git cannot remove (e.g. a path that is the main checkout), the rm_rf
      # fallback must NOT delete the repo. Point safe_cleanup at the repo path.
      log =
        capture_log(fn ->
          assert Worktree.safe_cleanup("git", ctx.repo, ctx.repo) == :ok
        end)

      # The repo is untouched — the guard refused.
      assert File.dir?(ctx.repo)
      assert File.regular?(Path.join(ctx.repo, "README.md"))
      assert log =~ "REFUSING"
    end

    test "safe_cleanup REFUSES to rm a path that contains the current cwd", ctx do
      cwd = File.cwd!()
      # A path that is an ancestor of the cwd (so removing it would delete cwd).
      ancestor = cwd |> Path.dirname() |> Path.dirname()

      log =
        capture_log(fn ->
          assert Worktree.safe_cleanup("git", ctx.repo, ancestor) == :ok
        end)

      assert File.dir?(cwd)
      assert log =~ "REFUSING"
    end
  end

  # issue #1074: distinct goal keys that share a 16-char prefix must not collide
  # on the same partition slug/branch.
  describe "slug_for/1 collision-proofing (issue #1074)" do
    test "distinct keys sharing a 16-char prefix get distinct, ref-safe slugs" do
      s11 = Worktree.slug_for(%{key: "valyrium-issue-11-openrouter-reasoning-object"})
      s12 = Worktree.slug_for(%{key: "valyrium-issue-12-cached-tokens-usage"})
      s13 = Worktree.slug_for(%{key: "valyrium-issue-13-something-else"})

      assert s11 != s12 and s12 != s13 and s11 != s13
      # deterministic: the same key re-slugs identically (idempotent re-propose).
      assert Worktree.slug_for(%{key: "valyrium-issue-11-openrouter-reasoning-object"}) == s11
      # git-ref / filesystem safe.
      for s <- [s11, s12, s13], do: assert(s =~ ~r/^p-[A-Za-z0-9_-]+$/)
    end

    test "a key with ref-forbidden characters is folded and still disambiguated" do
      a = Worktree.slug_for(%{key: "radius:lib/a.ex"})
      b = Worktree.slug_for(%{key: "radius:lib/b.ex"})
      assert a != b
      assert a =~ ~r/^p-[A-Za-z0-9_-]+$/
      assert b =~ ~r/^p-[A-Za-z0-9_-]+$/
    end
  end

  # issue #1081: a stuck/errored run's uncommitted collateral must be salvaged
  # to a durable ref BEFORE the worktree is force-removed, so verified work is
  # recoverable instead of destroyed.
  describe "safe_cleanup/3 salvages uncommitted collateral (issue #1081)" do
    # Manually add a partition worktree and return its path + branch.
    defp add_worktree(repo, base, name) do
      path = Path.join(base, name)
      run!(repo, ["worktree", "add", "-q", "-b", "kazi-partition/#{name}", path])
      path
    end

    test "a dirty worktree's tracked + untracked changes land in a salvage ref, then it is removed",
         %{repo: repo, base: base} do
      path = add_worktree(repo, base, "p-salv-1")

      # A tracked modification AND a brand-new untracked file -- both must survive.
      File.write!(Path.join(path, "README.md"), "edited by the agent\n")
      File.write!(Path.join(path, "new_feature.ex"), "defmodule NewFeature do\nend\n")

      assert Worktree.safe_cleanup("git", repo, path) == :ok

      # The worktree is gone (removal still happened).
      refute File.dir?(path)
      assert only_repo_listed?(repo)

      # A durable salvage ref exists and its commit carries BOTH changes.
      ref = "refs/kazi/salvage/p-salv-1"
      {rev, 0} = System.cmd("git", ["rev-parse", "--verify", "#{ref}^{commit}"], cd: repo)
      assert String.trim(rev) != ""

      {readme, 0} = System.cmd("git", ["show", "#{ref}:README.md"], cd: repo)
      assert readme =~ "edited by the agent"

      {feature, 0} = System.cmd("git", ["show", "#{ref}:new_feature.ex"], cd: repo)
      assert feature =~ "defmodule NewFeature"

      # The partition BRANCH was not advanced -- salvage is a dangling commit.
      {branch_head, 0} =
        System.cmd("git", ["rev-parse", "kazi-partition/p-salv-1"], cd: repo)

      refute String.trim(branch_head) == String.trim(rev)
    end

    test "a clean worktree salvages nothing (no salvage ref) and is removed", %{
      repo: repo,
      base: base
    } do
      path = add_worktree(repo, base, "p-clean-1")

      assert Worktree.safe_cleanup("git", repo, path) == :ok
      refute File.dir?(path)

      {out, _} = System.cmd("git", ["for-each-ref", "refs/kazi/salvage/"], cd: repo)
      refute out =~ "p-clean-1"
    end
  end
end

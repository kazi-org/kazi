defmodule Kazi.Providers.LandedTest do
  @moduledoc """
  T44.2 (ADR-0055): the `:landed` provider is the deterministic check that
  converged work has actually LANDED to its `[integration] mode` degree. These
  tests are the REAL boundary — a real `git` repo fixture driven through real
  `git init`/`commit`/`checkout`, never a mock of `git status` — so they prove:

    * a DIRTY tree fails, naming the dirty paths specifically (the actionable
      signal the loop feeds the next dispatch);
    * a clean tree committed on a NON-base branch passes for `:commit`;
    * a clean tree still sitting on the base branch fails (`:on_base_branch`);
    * `:branch` fails until the branch is pushed, then passes;
    * missing `gh` degrades `:pr`/`:merge` to `:unknown`, never a false `:fail`.

  The provider evaluates against the LIVE working tree (`context.workspace`) — the
  working-tree invariant (L-0024 / ADR-0042) that keeps `landed` from silently
  passing off a frozen clean ref.
  """
  use ExUnit.Case, async: true

  alias Kazi.Predicate
  alias Kazi.Providers.Landed

  # ===========================================================================
  # Clean-tree precondition (shared by every mode)
  # ===========================================================================

  describe "clean-tree precondition" do
    test "a dirty tree fails and names the dirty paths specifically" do
      dir = repo_on_branch("task/x", %{"app.ex" => "one\n"})
      File.write!(Path.join(dir, "app.ex"), "two\n")
      File.write!(Path.join(dir, "new.ex"), "brand new\n")

      result = evaluate(:commit, dir)

      assert result.status == :fail
      assert result.evidence.reason == :dirty_tree
      assert "app.ex" in result.evidence.dirty_paths
      assert "new.ex" in result.evidence.dirty_paths
    end

    test "an untracked-only file still fails the clean-tree check, named" do
      dir = repo_on_branch("task/x", %{"app.ex" => "one\n"})
      File.write!(Path.join(dir, "stranded.ex"), "uncommitted\n")

      result = evaluate(:commit, dir)

      assert result.status == :fail
      assert result.evidence.reason == :dirty_tree
      assert "stranded.ex" in result.evidence.dirty_paths
    end
  end

  # ===========================================================================
  # :commit — committed on a non-base branch
  # ===========================================================================

  describe ":commit mode" do
    test "clean tree committed on a non-base branch passes" do
      dir = repo_on_branch("task/x", %{"app.ex" => "one\n"})

      result = evaluate(:commit, dir)

      assert result.status == :pass
      assert result.evidence.mode == :commit
      assert result.evidence.branch == "task/x"
    end

    test "clean tree still on the base branch fails with :on_base_branch" do
      dir = repo_on_branch("main", %{"app.ex" => "one\n"})

      result = evaluate(:commit, dir, base: "main")

      assert result.status == :fail
      assert result.evidence.reason == :on_base_branch
      assert result.evidence.branch == "main"
      assert result.evidence.base == "main"
    end
  end

  # ===========================================================================
  # :branch — committed on a non-base branch AND pushed
  # ===========================================================================

  describe ":branch mode" do
    test "committed but unpushed fails with :branch_not_pushed" do
      dir = repo_on_branch("task/x", %{"app.ex" => "one\n"})

      result = evaluate(:branch, dir)

      assert result.status == :fail
      assert result.evidence.reason == :branch_not_pushed
      assert result.evidence.branch == "task/x"
    end

    test "pushed to a bare origin passes" do
      dir = repo_on_branch("task/x", %{"app.ex" => "one\n"})
      add_bare_origin_and_push(dir, "task/x")

      result = evaluate(:branch, dir)

      assert result.status == :pass
      assert result.evidence.mode == :branch
    end
  end

  # ===========================================================================
  # :pr / :merge — degrade honestly when gh cannot run
  # ===========================================================================

  describe ":pr / :merge landing state" do
    test ":pr never silently passes without a real open PR" do
      dir = repo_on_branch("task/x", %{"app.ex" => "one\n"})
      add_bare_origin_and_push(dir, "task/x")

      result = evaluate(:pr, dir)

      # The bare origin is not a GitHub remote, so no OPEN PR can be found: gh
      # missing degrades to :unknown, gh present resolves to :fail (:no_open_pr)
      # or :unknown. It is NEVER a silent :pass off a stale ref, and never a
      # crash-y :error (git itself works).
      assert result.status in [:unknown, :fail]
      refute result.status == :pass
    end

    test ":merge never silently passes without a merged PR" do
      dir = repo_on_branch("task/x", %{"app.ex" => "one\n"})
      add_bare_origin_and_push(dir, "task/x")

      result = evaluate(:merge, dir)

      assert result.status in [:unknown, :fail]
      refute result.status == :pass
    end
  end

  # ===========================================================================
  # non-git workspace / error surface
  # ===========================================================================

  describe "error surface" do
    test "a non-existent workspace is an :error, not a :fail" do
      result =
        evaluate(:commit, "/nonexistent/path/kazi_landed_#{System.unique_integer([:positive])}")

      assert result.status == :error
      assert result.evidence.reason in [:not_a_git_repo, :no_workspace]
    end

    test "a nil workspace is an :error" do
      result =
        Landed.evaluate(
          Predicate.new(:landed, :landed, config: %{mode: :commit, branch: "task/x"}),
          %{}
        )

      assert result.status == :error
      assert result.evidence.reason == :no_workspace
    end
  end

  # ===========================================================================
  # helpers — REAL git fixtures
  # ===========================================================================

  defp evaluate(mode, workspace, opts \\ []) do
    config = %{mode: mode, branch: "task/x", base: Keyword.get(opts, :base)}
    Landed.evaluate(Predicate.new(:landed, :landed, config: config), %{workspace: workspace})
  end

  defp repo_on_branch(branch, files) do
    dir = tmp_dir()
    git!(["init", "--initial-branch=main", dir])
    git!(["-C", dir, "config", "user.email", "t@example.com"])
    git!(["-C", dir, "config", "user.name", "t"])
    git!(["-C", dir, "config", "commit.gpgsign", "false"])

    write_files(dir, files)
    git!(["-C", dir, "add", "-A"])
    git!(["-C", dir, "commit", "-m", "seed"])

    unless branch == "main" do
      git!(["-C", dir, "checkout", "-b", branch])
    end

    dir
  end

  defp add_bare_origin_and_push(dir, branch) do
    remote = tmp_dir()
    git!(["init", "--bare", remote])
    git!(["-C", dir, "remote", "add", "origin", remote])
    git!(["-C", dir, "push", "-u", "origin", branch])
  end

  defp write_files(dir, files) do
    Enum.each(files, fn {rel, contents} ->
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)
  end

  defp git!(args) do
    {_out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    :ok
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "kazi_landed_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end

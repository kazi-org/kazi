defmodule Kazi.Actions.IntegrateSharedWorkspaceStagingTest do
  @moduledoc """
  The shared-workspace staging guard (T59.8, #937 Gap A4): a goal with no
  declared `[scope] paths` keeps the whole-workspace `git add -A` default ONLY
  when it is the solo holder of the working tree. When ANOTHER live run (a
  different `goal_ref`, classified live by the same fresh-heartbeat rule the
  T59.7 collision guard trusts) also holds the tree, a blind `-A` would absorb
  the co-tenant's uncommitted files into this goal's commit — the
  commit-boundary-corruption incident in #937 comment 5. In that case staging
  downgrades to `git add -u` (tracked modifications only), so a co-tenant's
  UNTRACKED file is never swept in.

  Real git boundary (Tier 2), same style as integrate_discipline_test.exs, plus
  a read-model sandbox so `RunRegistry.list_live/0` sees the seeded holder rows.
  """
  use ExUnit.Case, async: false

  alias Kazi.Action
  alias Kazi.Actions.Integrate
  alias Kazi.ReadModel.Run
  alias Kazi.Repo

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "no-scope goal in a SHARED workspace does not stage a co-tenant's untracked file",
       %{tmp_dir: tmp_dir} do
    %{work: work, bare: bare} = setup_repo(tmp_dir)

    # Another live run for a DIFFERENT goal holds this same working tree.
    insert_live_holder(work, goal_ref: "some-other-goal")

    # This goal's own tracked modification (must land) plus an unrelated
    # untracked file left by the co-tenant run (must NOT land).
    File.write!(Path.join(work, "README.md"), "seed\nmodified by this goal\n")
    File.write!(Path.join(work, "co-tenant.txt"), "another run's uncommitted work\n")

    integrator = fn request, _opts ->
      {:ok, %{pr: 1, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
    end

    action = Action.new(:integrate, params: %{branch: "kazi/shared-no-scope"})
    ctx = %{workspace: work, integrator: integrator, run_id: "this-run", goal_ref: "this-goal"}

    assert {:ok, _result} = Integrate.execute(action, ctx)

    {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
    refute tree =~ "co-tenant.txt"

    {readme, 0} = System.cmd("git", ["show", "main:README.md"], cd: bare)
    assert readme =~ "modified by this goal"
  end

  test "no-scope SOLO goal in an isolated worktree still commits its full authored diff",
       %{tmp_dir: tmp_dir} do
    %{work: work, bare: bare} = setup_repo(tmp_dir)

    # No live holder of this workspace -> the solo/isolated case. A brand-new
    # untracked file authored by this run must land alongside a tracked change.
    File.write!(Path.join(work, "README.md"), "seed\nmodified by this goal\n")
    File.write!(Path.join(work, "new-feature.txt"), "the converged fix\n")

    integrator = fn request, _opts ->
      {:ok, %{pr: 2, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
    end

    action = Action.new(:integrate, params: %{branch: "kazi/solo-no-scope"})
    ctx = %{workspace: work, integrator: integrator, run_id: "this-run", goal_ref: "this-goal"}

    assert {:ok, _result} = Integrate.execute(action, ctx)

    {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
    assert tree =~ "new-feature.txt"

    {readme, 0} = System.cmd("git", ["show", "main:README.md"], cd: bare)
    assert readme =~ "modified by this goal"
  end

  test "a STALE holder of the same workspace does not trip the guard (still -A)",
       %{tmp_dir: tmp_dir} do
    %{work: work, bare: bare} = setup_repo(tmp_dir)

    two_hours_ago = DateTime.utc_now(:microsecond) |> DateTime.add(-2, :hour)
    insert_live_holder(work, goal_ref: "some-other-goal", heartbeat_at: two_hours_ago)

    File.write!(Path.join(work, "new-feature.txt"), "the converged fix\n")

    integrator = fn request, _opts ->
      {:ok, %{pr: 3, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
    end

    action = Action.new(:integrate, params: %{branch: "kazi/stale-holder"})
    ctx = %{workspace: work, integrator: integrator, run_id: "this-run", goal_ref: "this-goal"}

    assert {:ok, _result} = Integrate.execute(action, ctx)

    {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
    assert tree =~ "new-feature.txt"
  end

  test "a live holder of the SAME goal_ref does not trip the guard (still -A)",
       %{tmp_dir: tmp_dir} do
    %{work: work, bare: bare} = setup_repo(tmp_dir)

    # Same goal_ref as this run -> not a cross-goal co-tenant; -A stays.
    insert_live_holder(work, goal_ref: "this-goal")

    File.write!(Path.join(work, "new-feature.txt"), "the converged fix\n")

    integrator = fn request, _opts ->
      {:ok, %{pr: 4, merge_commit: local_rebase_merge(bare, request.branch, request.base)}}
    end

    action = Action.new(:integrate, params: %{branch: "kazi/same-goal-holder"})
    ctx = %{workspace: work, integrator: integrator, run_id: "this-run", goal_ref: "this-goal"}

    assert {:ok, _result} = Integrate.execute(action, ctx)

    {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "main"], cd: bare)
    assert tree =~ "new-feature.txt"
  end

  defp insert_live_holder(workspace, attrs) do
    now = DateTime.utc_now(:microsecond)

    base = [
      run_id: "holder-#{System.unique_integer([:positive])}",
      pid: "#{System.unique_integer([:positive])}",
      workspace: to_string(workspace),
      goal_ref: "some-other-goal",
      status: "running",
      started_at: now,
      heartbeat_at: now
    ]

    {:ok, run} = Repo.insert(Run.changeset(%Run{}, Map.new(Keyword.merge(base, attrs))))
    run
  end

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
end

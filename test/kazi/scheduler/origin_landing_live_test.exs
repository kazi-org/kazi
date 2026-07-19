defmodule Kazi.Scheduler.OriginLandingLiveTest do
  @moduledoc """
  T62.5 (issue #1241 part 1): the LIVE, worktree-less origin-branch landing for
  `--parallel` per-group results.

  T44.10 (PR #1240) shipped the per-group landed-refs CONTRACT + surfaces but was
  deliberately scoped to the recording/integrator-tested seam only — no live
  proof that branches actually land on a real origin. This suite is that proof: a
  REAL 2-group `Scheduler.run_goals/2` run, with real git worktree isolation, a
  reconciler that makes real disjoint commits, and the REAL
  `Kazi.Scheduler.Integration.OriginIntegrator` (not a mock) landing each group's
  pushed branch onto a REAL throwaway bare `origin`. Every surfaced `landed` ref
  is then verified INDEPENDENTLY against a FRESH clone of that bare origin —
  branch exists, merge_commit is a real reachable commit on the base.

  Tagged `:integration` (real git, several worktrees + pushes) so the fast unit
  lane can skip it, consistent with the other live-fixture suites in `test/`.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.Coordination.Lease.Memory
  alias Kazi.Scheduler
  alias Kazi.Scheduler.Integration.OriginIntegrator
  alias Kazi.Scheduler.{PartitionSupervisor, Worktree}

  defmodule TermSource do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    @impl true
    def survey(_workspace, terms, opts) do
      mapping = Keyword.fetch!(opts, :mapping)

      files =
        terms
        |> Enum.flat_map(&Map.get(mapping, &1, []))
        |> Enum.uniq()
        |> Enum.map(&FileRef.new/1)

      Survey.new(:graph, files: files)
    end

    def new(mapping), do: {__MODULE__, mapping: mapping}
  end

  setup do
    {:ok, sup} = start_supervised(PartitionSupervisor)
    {:ok, store} = Memory.start_link()

    tmp = fn tag ->
      Path.join(System.tmp_dir!(), "kazi-oll-#{tag}-#{System.unique_integer([:positive])}")
    end

    origin = tmp.("origin")
    seed = tmp.("seed")
    workspace = tmp.("ws")
    base_dir = tmp.("base")

    # A real bare `origin` seeded from a throwaway checkout with one commit on main.
    git!(nil, ["init", "--bare", "-b", "main", origin])
    git!(nil, ["init", "-b", "main", seed])
    git_config!(seed)
    File.write!(Path.join(seed, "README.md"), "seed\n")
    git!(seed, ["add", "."])
    git!(seed, ["commit", "-q", "-m", "init"])
    git!(seed, ["remote", "add", "origin", origin])
    git!(seed, ["push", "-q", "origin", "main"])

    # The run's --workspace base: a real clone of origin (so it has an `origin`
    # remote + refs/remotes/origin/main — what OriginIntegrator lands against).
    git!(nil, ["clone", "-q", origin, workspace])
    git_config!(workspace)

    on_exit(fn ->
      for d <- [origin, seed, workspace, base_dir], do: File.rm_rf(d)
    end)

    %{
      sup: sup,
      store: store,
      origin: origin,
      workspace: workspace,
      base_dir: base_dir,
      seed_main_sha: origin_main_sha(origin)
    }
  end

  defp goal(id, terms), do: Kazi.Goal.new(id, metadata: %{partition_terms: terms})

  test "a live 2-group --parallel run lands each group on the real origin, verifiably",
       ctx do
    source = TermSource.new(%{"a" => ["a.txt"], "b" => ["b.txt"]})
    goals = [goal("g1", ["a"]), goal("g2", ["b"])]

    # A REAL reconciler: makes a disjoint commit in each partition's worktree
    # (distinct file per group, so the two group branches never conflict on main).
    reconciler = fn partition, path ->
      slug = Worktree.slug_for(partition)
      File.write!(Path.join(path, slug <> ".txt"), "work by #{slug}\n")
      {_out, 0} = System.cmd("git", ["add", "."], cd: path, stderr_to_stdout: true)

      {_out, 0} =
        System.cmd(
          "git",
          [
            "-c",
            "user.email=t@kazi",
            "-c",
            "user.name=kazi",
            "commit",
            "-q",
            "-m",
            "work " <> slug
          ],
          cd: path,
          stderr_to_stdout: true
        )

      :converged
    end

    assert {:ok, result} =
             Scheduler.run_goals(goals,
               workspace: ctx.workspace,
               graph_source: source,
               reconciler: reconciler,
               supervisor: ctx.sup,
               reconcile_timeout: 30_000,
               lease: [backend: Memory, lease_opts: [store: ctx.store]],
               worktree: [repo: ctx.workspace, base_dir: ctx.base_dir],
               integrate: [
                 integrator: &OriginIntegrator.integrate/2,
                 branch_prefix: "kazi-partition",
                 base: "main"
               ]
             )

    # The collective is GREEN: both groups converged AND landed live.
    assert result.collective == :converged
    assert length(result.integration.integrated) == 2
    assert result.integration.conflicts == []

    # Every surfaced ref carries a real branch + a real merge_commit sha, distinct
    # per group — the per-group landed contract, now proven live (not a stub).
    refs = for {_partition, r} <- result.integration.integrated, do: r
    branches = refs |> Enum.map(& &1.branch) |> Enum.sort()
    merge_commits = refs |> Enum.map(& &1.merge_commit)

    assert length(Enum.uniq(branches)) == 2
    assert Enum.all?(branches, &String.starts_with?(&1, "kazi-partition/"))
    assert Enum.all?(merge_commits, &(is_binary(&1) and byte_size(&1) == 40))
    assert length(Enum.uniq(merge_commits)) == 2

    # === INDEPENDENT verification against the actual origin state ===
    # A FRESH clone of the bare origin — nothing kazi touched — must show every
    # surfaced ref as real: the branch exists on origin, and each merge_commit is
    # a real commit reachable from origin/main.
    verify = Path.join(System.tmp_dir!(), "kazi-oll-verify-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(verify) end)
    git!(nil, ["clone", "-q", ctx.origin, verify])

    remote_branches = ls_remote_branches(ctx.origin)

    for branch <- branches do
      assert branch in remote_branches,
             "landed branch #{branch} is not on origin: #{inspect(remote_branches)}"
    end

    for sha <- merge_commits do
      # The commit object exists in origin's history...
      assert {_out, 0} = System.cmd("git", ["cat-file", "-e", sha <> "^{commit}"], cd: verify)
      # ...and is reachable from origin/main (it really landed on the base).
      assert {_out, 0} =
               System.cmd("git", ["merge-base", "--is-ancestor", sha, "origin/main"], cd: verify),
             "merge_commit #{sha} is not an ancestor of origin/main"
    end

    # Both groups' work is present on the landed base: each disjoint file made it.
    {tree, 0} = System.cmd("git", ["ls-tree", "-r", "--name-only", "origin/main"], cd: verify)

    group_files =
      tree |> String.split("\n", trim: true) |> Enum.filter(&String.ends_with?(&1, ".txt"))

    assert length(group_files) == 2
  end

  test "a mode:none parallel run (no :integrate) lands nothing and surfaces no refs",
       ctx do
    # Regression pin: without an integrator, the run converges but never touches
    # origin — no landing, no `:integration` key (byte-identical to pre-landing).
    source = TermSource.new(%{"a" => ["a.txt"]})

    assert {:ok, result} =
             Scheduler.run_goals([goal("solo", ["a"])],
               workspace: ctx.workspace,
               graph_source: source,
               reconciler: fn _p, _path -> :converged end,
               supervisor: ctx.sup,
               reconcile_timeout: 30_000,
               lease: [backend: Memory, lease_opts: [store: ctx.store]],
               worktree: [repo: ctx.workspace, base_dir: ctx.base_dir]
             )

    assert result.collective == :converged
    refute Map.has_key?(result, :integration)
    # No landing was configured, so nothing LANDED: origin's base (main) is
    # byte-identical to the seed. (The create-time upstream push of the isolation
    # worktree branch — issue #1075 — is unrelated to landing and pre-dates T62.5.)
    assert origin_main_sha(ctx.origin) == ctx.seed_main_sha
  end

  defp ls_remote_branches(origin) do
    {out, 0} = System.cmd("git", ["ls-remote", "--heads", origin], stderr_to_stdout: true)

    out
    |> String.split("\n", trim: true)
    |> Enum.map(fn line -> line |> String.split("\trefs/heads/") |> List.last() end)
    |> Enum.sort()
  end

  describe "OriginIntegrator error paths (no worktree needed)" do
    test "a missing origin_repo is an honest hard error" do
      assert {:error, :missing_origin_repo} =
               OriginIntegrator.integrate(%{branch: "kazi/p-x", base: "main"}, [])
    end

    test "a nil/absent branch is an honest hard error" do
      assert {:error, :no_branch} =
               OriginIntegrator.integrate(%{branch: nil, base: "main"}, origin_repo: "/tmp/x")

      assert {:error, :no_branch} =
               OriginIntegrator.integrate(%{base: "main"}, origin_repo: "/tmp/x")
    end

    test "a group branch absent from origin fails with :missing_origin_branch, never a silent ok",
         ctx do
      assert {:error, {:missing_origin_branch, "kazi-partition/never-pushed"}} =
               OriginIntegrator.integrate(
                 %{branch: "kazi-partition/never-pushed", base: "main"},
                 origin_repo: ctx.workspace
               )
    end
  end

  defp origin_main_sha(origin) do
    {out, 0} = System.cmd("git", ["ls-remote", origin, "refs/heads/main"], stderr_to_stdout: true)
    out |> String.split() |> List.first()
  end

  defp git_config!(dir) do
    git!(dir, ["config", "user.email", "t@kazi"])
    git!(dir, ["config", "user.name", "kazi"])
  end

  defp git!(dir, args) do
    opts = if dir, do: [cd: dir, stderr_to_stdout: true], else: [stderr_to_stdout: true]
    {_out, 0} = System.cmd("git", args, opts)
    :ok
  end
end

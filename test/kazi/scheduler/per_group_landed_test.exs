defmodule Kazi.Scheduler.PerGroupLandedTest do
  @moduledoc """
  T44.10 (ADR-0055): under `--parallel`, each converged partition lands on its OWN
  group-derived branch (`<branch_prefix>/<slug>`, reusing `Worktree.slug_for/1`),
  and the collective integration surfaces per-group landed refs
  (`{branch, pr, merge_commit}`) attributed to each partition.

  Hermetic (Tier 2): a real fixture git repo + the real `git` binary + an injected
  RECORDING integrator (no gh/network) — the same seam the scheduler-integration
  suite uses. The 2-goal disjoint set is the "2-group parallel run" the task pins.
  """
  use ExUnit.Case, async: true

  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.Coordination.Lease.Memory
  alias Kazi.Scheduler
  alias Kazi.Scheduler.{Integration, PartitionSupervisor, Worktree}

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

    repo = Path.join(System.tmp_dir!(), "kazi-pgl-repo-#{System.unique_integer([:positive])}")
    base = Path.join(System.tmp_dir!(), "kazi-pgl-base-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q"])
    git!(repo, ["config", "user.email", "t@kazi"])
    git!(repo, ["config", "user.name", "kazi"])
    File.write!(Path.join(repo, "README.md"), "x\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "init"])

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm_rf(base)
    end)

    %{sup: sup, store: store, repo: repo, base: base}
  end

  defp goal(id, terms), do: Kazi.Goal.new(id, metadata: %{partition_terms: terms})

  test "a 2-group parallel run lands each group on a DISTINCT group-derived branch", ctx do
    source = TermSource.new(%{"a" => ["lib/a.ex"], "b" => ["lib/b.ex"]})
    goals = [goal("g1", ["a"]), goal("g2", ["b"])]
    test_pid = self()

    # Recording integrator: captures the per-group branch each request lands on
    # and returns distinct refs keyed by the request key.
    integrator = fn request, _opts ->
      send(test_pid, {:landing, request.branch, request.key})
      {:ok, %{pr: "pr-" <> request.key, merge_commit: "sha-" <> request.key}}
    end

    assert {:ok, result} =
             Scheduler.run_goals(goals,
               workspace: ctx.repo,
               graph_source: source,
               reconciler: fn _part, _path -> :converged end,
               supervisor: ctx.sup,
               reconcile_timeout: 5_000,
               lease: [backend: Memory, lease_opts: [store: ctx.store]],
               worktree: [repo: ctx.repo, base_dir: ctx.base],
               integrate: [integrator: integrator, branch_prefix: "kazi"]
             )

    assert result.collective == :converged
    assert length(result.integration.integrated) == 2

    # Two DISTINCT group-derived branches were requested (not one reused).
    assert_receive {:landing, branch1, _}
    assert_receive {:landing, branch2, _}
    assert branch1 != branch2
    assert String.starts_with?(branch1, "kazi/")
    assert String.starts_with?(branch2, "kazi/")

    # Each partition's surfaced refs carry its OWN branch + pr + merge_commit,
    # distinct per group — the "2 separate branch/PR records" the task pins.
    refs = for {_partition, r} <- result.integration.integrated, do: r
    branches = refs |> Enum.map(& &1.branch) |> Enum.sort()
    prs = refs |> Enum.map(& &1.pr) |> Enum.sort()

    assert length(Enum.uniq(branches)) == 2
    assert length(Enum.uniq(prs)) == 2
    assert Enum.all?(refs, &Map.has_key?(&1, :merge_commit))
  end

  test "the landing branch reuses Worktree.slug_for/1 and honors branch_prefix", ctx do
    source = TermSource.new(%{"a" => ["lib/a.ex"]})
    goals = [goal("solo", ["a"])]
    test_pid = self()

    integrator = fn request, _opts ->
      send(test_pid, {:landing, request.partition, request.branch})
      {:ok, %{pr: 1}}
    end

    assert {:ok, _result} =
             Scheduler.run_goals(goals,
               workspace: ctx.repo,
               graph_source: source,
               reconciler: fn _part, _path -> :converged end,
               supervisor: ctx.sup,
               reconcile_timeout: 5_000,
               lease: [backend: Memory, lease_opts: [store: ctx.store]],
               worktree: [repo: ctx.repo, base_dir: ctx.base],
               integrate: [integrator: integrator, branch_prefix: "release"]
             )

    assert_receive {:landing, partition, branch}
    # The exact derivation the worktree layer uses — no bespoke naming scheme.
    assert branch == "release/" <> Worktree.slug_for(partition)
  end

  describe "Integration.integrate/2 — 3-tuple entries" do
    test "a {partition, worktree, branch} entry threads the branch into the refs" do
      test_pid = self()

      integrator = fn request, _opts ->
        send(test_pid, {:req, request.branch})
        {:ok, %{pr: 7}}
      end

      entries = [{%{key: "k1"}, nil, "kazi/p-one"}, {%{key: "k2"}, nil, "kazi/p-two"}]

      assert {:ok, result} = Integration.integrate(entries, integrator: integrator)
      assert result.collective == :converged

      landed_branches =
        for {_p, refs} <- result.integrated, do: refs.branch

      assert Enum.sort(landed_branches) == ["kazi/p-one", "kazi/p-two"]

      # The integrator SAW the distinct per-group branch on each request.
      assert_receive {:req, "kazi/p-one"}
      assert_receive {:req, "kazi/p-two"}
    end

    test "an integrator that returns its OWN branch wins over the entry branch" do
      integrator = fn _request, _opts -> {:ok, %{pr: 1, branch: "actual/branch"}} end
      entries = [{%{key: "k"}, nil, "derived/branch"}]

      assert {:ok, %{integrated: [{_p, refs}]}} =
               Integration.integrate(entries, integrator: integrator)

      assert refs.branch == "actual/branch"
    end
  end

  defp git!(dir, args) do
    {_out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    :ok
  end
end

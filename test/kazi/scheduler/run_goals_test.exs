defmodule Kazi.Scheduler.RunGoalsTest do
  @moduledoc """
  End-to-end composition (T21.2/T21.3/T21.4, ADR-0027): `Kazi.Scheduler.run_goals/2`
  partitions a goal-set by blast radius, brackets each partition with its
  in-memory lease AND an isolated git worktree, runs them under the
  `DynamicSupervisor`, and folds the collective verdict.

  Hermetic: an injected graph source (per-term file mapping), a real in-memory
  lease store (the single-node default, no NATS), a real fixture git repo, the
  real `git` binary, and an injected inner reconciler — no harness, no network.
  """
  use ExUnit.Case, async: true

  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.Coordination.Lease.Memory
  alias Kazi.Scheduler
  alias Kazi.Scheduler.PartitionSupervisor

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

    repo = Path.join(System.tmp_dir!(), "kazi-rg-repo-#{System.unique_integer([:positive])}")
    base = Path.join(System.tmp_dir!(), "kazi-rg-base-#{System.unique_integer([:positive])}")
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

  defp git!(repo, args), do: {_o, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)

  defp goal(id, terms), do: Kazi.Goal.new(id, metadata: %{partition_terms: terms})

  test "disjoint goals run as separate leased + worktree-isolated partitions", ctx do
    source = TermSource.new(%{"a" => ["lib/a.ex"], "b" => ["lib/b.ex"]})
    goals = [goal("g1", ["a"]), goal("g2", ["b"])]
    test_pid = self()

    inner = fn part, worktree_path ->
      # The inner sees its partition's goals AND an isolated worktree under base.
      send(test_pid, {:ran, hd(part.goals).id, worktree_path, File.dir?(worktree_path)})
      :converged
    end

    assert {:ok, result} =
             Scheduler.run_goals(goals,
               workspace: ctx.repo,
               graph_source: source,
               reconciler: inner,
               supervisor: ctx.sup,
               reconcile_timeout: 5_000,
               lease: [backend: Memory, lease_opts: [store: ctx.store]],
               worktree: [repo: ctx.repo, base_dir: ctx.base]
             )

    assert result.collective == :converged
    assert length(result.partitions) == 2

    # Each partition ran in its OWN worktree under the managed base dir.
    ran =
      for _ <- goals do
        assert_receive {:ran, id, path, true}
        {id, path}
      end

    paths = Enum.map(ran, &elem(&1, 1))
    assert paths |> Enum.uniq() |> length() == 2
    assert Enum.all?(paths, &String.starts_with?(Path.expand(&1), Path.expand(ctx.base)))
    # Worktrees cleaned up on terminal.
    assert Enum.all?(paths, &(not File.dir?(&1)))
  end

  test "a single goal degenerates to one partition (serial parity, still isolated)", ctx do
    source = TermSource.new(%{"a" => ["lib/a.ex"]})
    inner = fn _part, _path -> :converged end

    assert {:ok, result} =
             Scheduler.run_goals([goal("solo", ["a"])],
               workspace: ctx.repo,
               graph_source: source,
               reconciler: inner,
               supervisor: ctx.sup,
               reconcile_timeout: 5_000,
               lease: [backend: Memory, lease_opts: [store: ctx.store]],
               worktree: [repo: ctx.repo, base_dir: ctx.base]
             )

    assert result.collective == :converged
    assert length(result.partitions) == 1
  end

  test "overlapping goals collapse to one partition (one lease, one worktree)", ctx do
    source = TermSource.new(%{"a" => ["lib/shared.ex"], "b" => ["lib/shared.ex"]})
    goals = [goal("g1", ["a"]), goal("g2", ["b"])]
    test_pid = self()

    inner = fn part, _path ->
      send(test_pid, {:partition_goals, Enum.map(part.goals, & &1.id)})
      :converged
    end

    assert {:ok, result} =
             Scheduler.run_goals(goals,
               workspace: ctx.repo,
               graph_source: source,
               reconciler: inner,
               supervisor: ctx.sup,
               reconcile_timeout: 5_000,
               lease: [backend: Memory, lease_opts: [store: ctx.store]],
               worktree: [repo: ctx.repo, base_dir: ctx.base]
             )

    assert result.collective == :converged
    # ONE partition carrying BOTH goals (overlap merged them).
    assert length(result.partitions) == 1
    assert_received {:partition_goals, ["g1", "g2"]}
  end
end

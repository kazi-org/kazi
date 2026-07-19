defmodule Kazi.Scheduler.SupervisionTest do
  @moduledoc """
  T21.10 acceptance (ADR-0027): supervision / restart + escalation.

  A crashed partition reconciler is CONTAINED — the coordinator survives the child
  crash and the partition reports `:crashed`/`:stuck` (never a false converge).
  With a restart budget, a crashed reconciler RESTARTS up to `:max_restarts` times
  before escalating. Lease + worktree are released/cleaned even on crash (the
  T21.3/T21.4 `try/after` cleanup), so a restart never inherits dangling state.

  Hermetic: stub reconcilers (a raise, a process kill), a real in-memory lease
  store, a real fixture git repo + the real `git` binary for the worktree — no
  harness, no network, no NATS. Each test starts its own isolated
  `PartitionSupervisor` so the cases run `async`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kazi.Coordination.Lease.Memory
  alias Kazi.Scheduler
  alias Kazi.Scheduler.{LeasedReconciler, PartitionSupervisor, Worktree}

  setup do
    {:ok, sup} = start_supervised(PartitionSupervisor)
    %{sup: sup}
  end

  describe "crash containment (coordinator survives, no false converge)" do
    test "a raising reconciler is contained as :crashed; siblings + coordinator survive",
         %{sup: sup} do
      reconciler = fn
        :ok1 -> :converged
        :boom -> raise "stub crash"
        :ok2 -> :converged
      end

      capture_log(fn ->
        assert {:ok, result} =
                 Scheduler.run([:ok1, :boom, :ok2], reconciler: reconciler, supervisor: sup)

        # The crashed partition is :crashed (NOT a false :converged); siblings
        # converged; the collective is :stuck (a crash folds into stuck).
        assert result.partitions == [{:ok1, :converged}, {:boom, :crashed}, {:ok2, :converged}]
        assert result.collective == :stuck
      end)
    end

    test "a reconciler that hard-kills its process is contained; coordinator survives",
         %{sup: sup} do
      # A genuine process exit (not a caught raise): kill the reconcile task. With
      # no restart budget this escalates straight to :crashed, and the coordinator
      # — which only monitors the child — survives.
      reconciler = fn
        :victim -> Process.exit(self(), :kill)
        :survivor -> :converged
      end

      capture_log(fn ->
        assert {:ok, result} =
                 Scheduler.run([:victim, :survivor], reconciler: reconciler, supervisor: sup)

        assert {:victim, :crashed} in result.partitions
        assert {:survivor, :converged} in result.partitions
        assert result.collective == :stuck
      end)
    end

    test "the coordinator process stays alive after a child crash", %{sup: sup} do
      # Prove the coordinator survives by completing a normal run AFTER one whose
      # child crashed, on the same supervisor.
      crashing = fn :x -> raise "boom" end

      capture_log(fn ->
        assert {:ok, _} = Scheduler.run([:x], reconciler: crashing, supervisor: sup)
      end)

      assert {:ok, result} =
               Scheduler.run([:y], reconciler: fn :y -> :converged end, supervisor: sup)

      assert result.collective == :converged
    end
  end

  describe "restart policy (T21.10)" do
    test "a crashed reconciler restarts up to :max_restarts, then converges", %{sup: sup} do
      # The partition crashes its first 2 attempts (real process kills), then
      # converges on the 3rd. With max_restarts: 2 it is restarted twice and the
      # 3rd attempt succeeds — so the partition converges rather than escalating.
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      reconciler = fn :flaky ->
        n = Agent.get_and_update(attempts, fn a -> {a + 1, a + 1} end)
        if n <= 2, do: Process.exit(self(), :kill), else: :converged
      end

      capture_log(fn ->
        assert {:ok, result} =
                 Scheduler.run([:flaky],
                   reconciler: reconciler,
                   supervisor: sup,
                   max_restarts: 2,
                   reconcile_timeout: 2_000
                 )

        assert result.partitions == [{:flaky, :converged}]
        assert result.collective == :converged
      end)

      # Exactly 3 invocations: 2 crashes + 1 success.
      assert Agent.get(attempts, & &1) == 3
    end

    test "a reconciler that crashes beyond the budget escalates to :crashed", %{sup: sup} do
      # Crashes every time; with max_restarts: 1 it gets 1 restart (2 total
      # invocations) then escalates to :crashed (never a false converge).
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      reconciler = fn :doomed ->
        Agent.update(attempts, &(&1 + 1))
        Process.exit(self(), :kill)
      end

      capture_log(fn ->
        assert {:ok, result} =
                 Scheduler.run([:doomed],
                   reconciler: reconciler,
                   supervisor: sup,
                   max_restarts: 1,
                   reconcile_timeout: 2_000
                 )

        assert result.partitions == [{:doomed, :crashed}]
        assert result.collective == :stuck
      end)

      # 1 initial + 1 restart = 2 invocations before escalation.
      assert Agent.get(attempts, & &1) == 2
    end

    test "max_restarts: 0 (default) escalates a crash immediately", %{sup: sup} do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      reconciler = fn :x ->
        Agent.update(attempts, &(&1 + 1))
        Process.exit(self(), :kill)
      end

      capture_log(fn ->
        assert {:ok, result} = Scheduler.run([:x], reconciler: reconciler, supervisor: sup)
        assert result.partitions == [{:x, :crashed}]
      end)

      # Exactly one invocation — no restart.
      assert Agent.get(attempts, & &1) == 1
    end
  end

  describe "lease + worktree are cleaned even on crash" do
    setup do
      {:ok, store} = Memory.start_link()

      repo = mk_repo()
      base = Path.join(System.tmp_dir!(), "kazi-sup-base-#{System.unique_integer([:positive])}")

      on_exit(fn ->
        File.rm_rf(repo)
        File.rm_rf(base)
      end)

      %{store: store, repo: repo, base: base}
    end

    test "a crashing leased reconciler still releases its lease", ctx do
      key = "p-crash"
      part = %{key: key}

      reconciler =
        LeasedReconciler.wrap(
          fn _p -> raise "crash while holding the lease" end,
          backend: Memory,
          lease_opts: [store: ctx.store],
          ttl_ms: 60_000
        )

      # The wrapped reconciler raises while holding the lease; the try/after
      # releases it as the process unwinds. After it returns, the lease is FREE —
      # a fresh acquire on the same key succeeds.
      capture_log(fn ->
        assert_raise RuntimeError, fn -> reconciler.(part) end
      end)

      assert {:ok, _lease} =
               Memory.acquire(key, "someone-else", 60_000, store: ctx.store)
    end

    test "a crashing worktree reconciler still removes its worktree", ctx do
      part = %{key: "p-wt"}
      test_pid = self()

      reconciler =
        Worktree.wrap(
          fn _p, worktree_path ->
            send(test_pid, {:worktree, worktree_path})
            raise "crash inside the worktree"
          end,
          repo: ctx.repo,
          base_dir: ctx.base
        )

      capture_log(fn ->
        assert_raise RuntimeError, fn -> reconciler.(part) end
      end)

      # The worktree existed during the run, and was removed on the crash unwind.
      assert_received {:worktree, path}
      refute File.dir?(path)
      # git's own worktree list no longer references it (removed, not leaked).
      {out, 0} = System.cmd("git", ["worktree", "list"], cd: ctx.repo)
      refute out =~ Path.basename(path)
    end

    test "run_goals/2: a crashing partition is contained, lease + worktree cleaned, reports crash",
         ctx do
      sup = ctx.sup
      source = term_source(%{"a" => ["lib/a.ex"], "b" => ["lib/b.ex"]})
      goals = [goal("g1", ["a"]), goal("g2", ["b"])]
      test_pid = self()

      inner = fn part, worktree_path ->
        case hd(part.goals).id do
          "g1" ->
            send(test_pid, {:wt, "g1", worktree_path})
            raise "g1 crashes"

          "g2" ->
            :converged
        end
      end

      capture_log(fn ->
        assert {:ok, result} =
                 Scheduler.run_goals(goals,
                   workspace: ctx.repo,
                   graph_source: source,
                   reconciler: inner,
                   supervisor: sup,
                   reconcile_timeout: 5_000,
                   lease: [backend: Memory, lease_opts: [store: ctx.store]],
                   worktree: [repo: ctx.repo, base_dir: ctx.base]
                 )

        # g1 crashed (NOT a false converge), g2 converged, collective stuck.
        statuses = Map.new(result.partitions, fn {p, s} -> {hd(p.goals).id, s} end)
        assert statuses["g1"] == :crashed
        assert statuses["g2"] == :converged
        assert result.collective == :stuck
      end)

      # g1's worktree was created then removed on the crash.
      assert_received {:wt, "g1", g1_path}
      refute File.dir?(g1_path)

      # g1's lease was released on the crash — re-acquirable.
      assert {:ok, _} =
               Memory.acquire("a", "after-crash", 60_000, store: ctx.store)
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp mk_repo do
    repo = Path.join(System.tmp_dir!(), "kazi-sup-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q"])
    git!(repo, ["config", "user.email", "t@kazi"])
    git!(repo, ["config", "user.name", "kazi"])
    File.write!(Path.join(repo, "README.md"), "x\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "init"])
    repo
  end

  defp git!(repo, args), do: {_o, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)

  defp goal(id, terms), do: Kazi.Goal.new(id, metadata: %{partition_terms: terms})

  defp term_source(mapping) do
    {Kazi.Scheduler.SupervisionTest.TermSource, mapping: mapping}
  end

  defmodule TermSource do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    alias Kazi.Context.{FileRef, Survey}

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
  end
end

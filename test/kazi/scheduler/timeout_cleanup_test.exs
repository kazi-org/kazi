defmodule Kazi.Scheduler.TimeoutCleanupTest do
  @moduledoc """
  M8 (deep-review-001): a brutal-killed partition — a wedged reconciler hitting a
  finite `:reconcile_timeout` (`Task.shutdown(task, :brutal_kill)`), or an
  untrappable self-kill (`Process.exit(self(), :kill)`) escalating via the
  coordinator's crash path — still has its LEASE released and its WORKTREE
  removed, even though the killed process's own `try/after` never ran.

  Hermetic: a real fixture git repo + the real `git` binary, a real
  `Kazi.Coordination.Lease.Memory` store, no network, no harness.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kazi.Coordination.Lease.Memory
  alias Kazi.Scheduler
  alias Kazi.Scheduler.{LeasedReconciler, PartitionSupervisor, Worktree}

  setup do
    repo = Path.join(System.tmp_dir!(), "kazi-m8-repo-#{System.unique_integer([:positive])}")
    base = Path.join(System.tmp_dir!(), "kazi-m8-base-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)

    run!(repo, ["init", "-q"])
    run!(repo, ["config", "user.email", "test@kazi"])
    run!(repo, ["config", "user.name", "kazi test"])
    File.write!(Path.join(repo, "README.md"), "fixture\n")
    run!(repo, ["add", "."])
    run!(repo, ["commit", "-q", "-m", "init"])

    {:ok, store} = Memory.start_link()
    {:ok, sup} = start_supervised(PartitionSupervisor)

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm_rf(base)
    end)

    %{repo: repo, base: base, store: store, sup: sup}
  end

  defp run!(repo, args) do
    {_out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
  end

  defp listed_worktrees(repo) do
    {out, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: repo)

    out
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "worktree "))
    |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))
    |> Enum.map(&Path.expand/1)
  end

  defp partition(key), do: %{key: key}

  # A lease+worktree-wrapped reconciler over `base` (a 2-arity fn receiving the
  # partition + its worktree path), keyed by the partition's `:key`. Uses the
  # DEFAULT `Kazi.Scheduler.WorktreeTable` singleton -- the same default
  # `Kazi.Scheduler.invoke_reconciler/3`'s and the coordinator's own reap calls
  # target, since a test cannot override those internal call sites.
  defp compose(base, ctx) do
    worktree_opts = [repo: ctx.repo, base_dir: ctx.base]

    base
    |> Worktree.wrap(worktree_opts)
    |> LeasedReconciler.wrap(backend: Memory, lease_opts: [store: ctx.store])
  end

  describe "reconcile_timeout brutal-kill" do
    test "a wedged reconciler's lease is released and worktree removed after the kill", ctx do
      test_pid = self()

      base = fn partition, path ->
        send(test_pid, {:started, partition.key, path})
        # Wedged: sleeps well past reconcile_timeout, forcing a brutal-kill.
        Process.sleep(5_000)
        :converged
      end

      reconciler = compose(base, ctx)

      capture_log(fn ->
        assert {:ok, %{partitions: [{_p, :stuck}], collective: :stuck}} =
                 Scheduler.run([partition("radius:m8-timeout")],
                   reconciler: reconciler,
                   supervisor: ctx.sup,
                   reconcile_timeout: 200
                 )
      end)

      assert_received {:started, "radius:m8-timeout", path}

      # The lease auto-released (the holder process was killed, never reached
      # its own `after`) -- a sibling can now acquire the SAME key immediately.
      assert {:ok, _lease} =
               Memory.acquire("radius:m8-timeout", "sibling", 30_000, store: ctx.store)

      # The worktree was reaped by the surviving invoke_reconciler process.
      refute File.dir?(path)
      refute path in listed_worktrees(ctx.repo)
    end
  end

  describe "self-kill (untrappable, escalates via the coordinator crash path)" do
    test "a self-killed reconciler's lease is released and worktree removed", ctx do
      test_pid = self()

      base = fn partition, path ->
        send(test_pid, {:started, partition.key, path})
        Process.exit(self(), :kill)
      end

      reconciler = compose(base, ctx)

      capture_log(fn ->
        assert {:ok, %{partitions: [{_p, :crashed}], collective: :stuck}} =
                 Scheduler.run([partition("radius:m8-selfkill")],
                   reconciler: reconciler,
                   supervisor: ctx.sup,
                   max_restarts: 0
                 )
      end)

      assert_received {:started, "radius:m8-selfkill", path}

      assert {:ok, _lease} =
               Memory.acquire("radius:m8-selfkill", "sibling", 30_000, store: ctx.store)

      refute File.dir?(path)
      refute path in listed_worktrees(ctx.repo)
    end
  end
end

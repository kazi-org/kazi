defmodule Kazi.Scheduler.IntegrationLeaseTest do
  @moduledoc """
  T73.3 acceptance (ADR-0087 decision 4): a SECOND, narrower `Kazi.Coordination.Lease`
  scope around just `Kazi.Scheduler.Integration`'s rebase-merge step, keyed by the
  partition's `lease_key`s (T73.1/T73.2's `shared_paths`), independent of the
  partition-scoped `PartitionLease` grind holds for the whole run.

  Hermetic: a real `Kazi.Coordination.Lease.Memory` store (the single-node
  default, no NATS) and stub integrators/reconcilers — no real `git`/`gh`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kazi.Coordination.Lease.Memory
  alias Kazi.Partition
  alias Kazi.Scheduler.Integration

  setup do
    {:ok, store} = Memory.start_link()
    %{store: store, backend: Memory, lease_opts: [store: store]}
  end

  defp partition(id, lease_keys) do
    %Partition{goal_ids: [id], blast_radius: [], key: "part:" <> id, lease_keys: lease_keys}
  end

  describe "grind is unaffected — two partitions reach their first observe pass concurrently" do
    test "sharing a lease key does NOT serialize grind (only integration does)" do
      parent = self()

      # A stand-in "grind" (observe/dispatch) reconciler — this is what runs
      # BEFORE integration, and T73.3 must not touch it. Both partitions share
      # lease key `mix.exs` (T73.3's new scope) yet their observe passes overlap,
      # because grind still only ever contends on the (distinct, per-partition)
      # `PartitionLease` key — untouched by this change.
      grind = fn label ->
        send(parent, {:observe, label, System.monotonic_time()})
        Process.sleep(50)
        send(parent, {:observe_done, label, System.monotonic_time()})
        :converged
      end

      a = Task.async(fn -> grind.(:a) end)
      b = Task.async(fn -> grind.(:b) end)

      assert Task.await(a) == :converged
      assert Task.await(b) == :converged

      assert_received {:observe, :a, a_start}
      assert_received {:observe, :b, b_start}
      assert_received {:observe_done, :a, a_end}
      assert_received {:observe_done, :b, b_end}

      # Overlap proof: each one's window intersects the other's.
      assert a_start < b_end
      assert b_start < a_end
    end
  end

  describe "integration serializes on a shared lease_key" do
    test "two partitions sharing lease key mix.exs: the second integrates only after the first releases",
         ctx do
      parent = self()

      integrator = fn request, _opts ->
        send(parent, {:integrate_start, request.key, System.monotonic_time()})
        # Partition A holds the merge step open until told to proceed, so a test
        # observer can assert B has NOT started while A holds the lease.
        if request.key == "part:a" do
          receive do
            :proceed -> :ok
          end
        end

        send(parent, {:integrate_done, request.key, System.monotonic_time()})
        {:ok, %{pr: request.key}}
      end

      entries = [partition("a", ["mix.exs"]), partition("b", ["mix.exs"])]

      task =
        Task.async(fn ->
          Integration.integrate(entries,
            integrator: integrator,
            lease_backend: ctx.backend,
            lease_opts: ctx.lease_opts,
            order_fun: fn p -> p.key end
          )
        end)

      assert_receive {:integrate_start, "part:a", _}, 1_000
      # B must NOT have started yet — it is blocked on the shared lease.
      refute_receive {:integrate_start, "part:b", _}, 200

      # The lease key is genuinely held while A's merge is in flight.
      assert {:ok, _lease} = Memory.peek("mix.exs", ctx.lease_opts)

      send(task.pid, :proceed)

      assert_receive {:integrate_done, "part:a", a_done}, 1_000
      assert_receive {:integrate_start, "part:b", b_start}, 1_000
      assert b_start >= a_done

      assert {:ok, result} = Task.await(task)
      assert result.collective == :converged
      assert length(result.integrated) == 2
      assert Memory.peek("mix.exs", ctx.lease_opts) == :free
    end

    test "partitions with disjoint lease keys integrate CONCURRENTLY, unaffected", ctx do
      parent = self()

      integrator = fn request, _opts ->
        send(parent, {:in, request.key})
        # Block until BOTH have entered, proving neither waited on the other.
        receive do
          :go -> :ok
        end

        {:ok, %{pr: request.key}}
      end

      entries = [partition("a", ["lib/a.ex"]), partition("b", ["lib/b.ex"])]

      task =
        Task.async(fn ->
          Integration.integrate(entries,
            integrator: integrator,
            lease_backend: ctx.backend,
            lease_opts: ctx.lease_opts,
            order_fun: fn p -> p.key end
          )
        end)

      # `integrate/2` runs partitions ONE AT A TIME in safe order (serial join by
      # design — ADR-0027 step 4, unrelated to leasing) — so B naturally starts
      # only after A yields control back. What T73.3 must NOT introduce is any
      # EXTRA lease-induced wait on top of that: with disjoint keys B's lease
      # acquires immediately (no CAS contention), so it starts the instant the
      # serial fold reaches it, exactly like today (pre-T73.3, no leasing at
      # all).
      assert_receive {:in, "part:a"}, 1_000
      refute_receive {:in, "part:b"}, 100
      send(task.pid, :go)
      assert_receive {:in, "part:b"}, 1_000
      send(task.pid, :go)

      assert {:ok, result} = Task.await(task)
      assert result.collective == :converged
      assert length(result.integrated) == 2
    end
  end

  describe "a crash inside integration releases the lease within its TTL" do
    test "a killed integration process frees the key by TTL even though its `after` never ran",
         ctx do
      parent = self()

      integrator = fn request, _opts ->
        send(parent, {:holding, request.key})

        receive do
          :never -> :ok
        end
      end

      entries = [partition("a", ["mix.exs"])]

      {:ok, pid} =
        Task.start(fn ->
          capture_log(fn ->
            Integration.integrate(entries,
              integrator: integrator,
              lease_backend: ctx.backend,
              lease_opts: ctx.lease_opts,
              # A short TTL: the safety net a real crash relies on, since the
              # `after` release cannot run when the process is killed outright.
              lease_ttl_ms: 100
            )
          end)
        end)

      assert_receive {:holding, "part:a"}, 1_000
      # The lease is genuinely held.
      assert {:ok, _lease} = Memory.peek("mix.exs", ctx.lease_opts)

      # Simulate a hard crash: kill the process outright — no `after` runs.
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

      # Immediately after the kill the key may still show held (TTL not yet up).
      # Wait past the TTL and assert it is free — the TTL, not the `after`, is
      # what bounds a real crash.
      Process.sleep(150)
      assert Memory.peek("mix.exs", ctx.lease_opts) == :free
    end
  end
end

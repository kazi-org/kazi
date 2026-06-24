defmodule Kazi.Scheduler.LeasedReconcilerTest do
  @moduledoc """
  T21.3 acceptance (ADR-0027), in-memory lease: each partition acquires + releases
  its lease around its run; two overlapping-radius partitions SERIALIZE (one
  waits); leases are released on terminal — INCLUDING on crash.

  Hermetic: a real `Kazi.Coordination.Lease.Memory` store (the single-node
  default, NOT a stub) and no NATS. The inner reconciler is an injected stub.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kazi.Coordination.Lease
  alias Kazi.Coordination.Lease.Memory
  alias Kazi.Scheduler.LeasedReconciler

  setup do
    {:ok, store} = Memory.start_link()
    %{store: store, backend: Memory, lease_opts: [store: store]}
  end

  # A partition shape carrying its lease key (a Partitioner entry shape).
  defp partition(key), do: %{key: key}

  describe "acquire on start / release on terminal" do
    test "the lease is HELD during the run and FREE after it returns", ctx do
      key = "radius:lib/a.ex"
      test_pid = self()

      inner = fn _partition ->
        # Observe the lease IS held mid-run.
        send(test_pid, {:held?, Memory.peek(key, ctx.lease_opts)})
        :converged
      end

      reconciler =
        LeasedReconciler.wrap(inner, backend: ctx.backend, lease_opts: ctx.lease_opts)

      assert reconciler.(partition(key)) == :converged
      # Mid-run: a live lease held the key.
      assert_received {:held?, {:ok, %Lease{key: ^key}}}
      # After terminal: the key is free again (released).
      assert Memory.peek(key, ctx.lease_opts) == :free
    end

    test "the lease is released even when the run returns an error", ctx do
      key = "radius:lib/err.ex"
      inner = fn _partition -> {:error, :boom} end

      reconciler =
        LeasedReconciler.wrap(inner, backend: ctx.backend, lease_opts: ctx.lease_opts)

      assert reconciler.(partition(key)) == {:error, :boom}
      assert Memory.peek(key, ctx.lease_opts) == :free
    end
  end

  describe "release on crash (terminal incl. crash)" do
    test "a raising reconciler still releases its lease as it unwinds", ctx do
      key = "radius:lib/crash.ex"
      inner = fn _partition -> raise "kaboom" end

      reconciler =
        LeasedReconciler.wrap(inner, backend: ctx.backend, lease_opts: ctx.lease_opts)

      capture_log(fn ->
        assert_raise RuntimeError, "kaboom", fn -> reconciler.(partition(key)) end
      end)

      # The `after` ran during unwind: the lease is freed despite the crash.
      assert Memory.peek(key, ctx.lease_opts) == :free
    end
  end

  describe "overlapping partitions SERIALIZE on the shared lease" do
    test "two partitions with the SAME key — the second waits for the first", ctx do
      key = "radius:lib/shared.ex"
      parent = self()

      # The first holder blocks until released by the test, holding the lease.
      first =
        LeasedReconciler.wrap(
          fn _p ->
            send(parent, :first_in)

            receive do
              :release_first -> :converged
            end
          end,
          backend: ctx.backend,
          lease_opts: ctx.lease_opts,
          retry_interval_ms: 5
        )

      # The second contends on the SAME key; it must not enter until the first
      # releases. It records the order it actually ran in.
      second =
        LeasedReconciler.wrap(
          fn _p ->
            send(parent, :second_in)
            :converged
          end,
          backend: ctx.backend,
          lease_opts: ctx.lease_opts,
          retry_interval_ms: 5,
          acquire_timeout_ms: 2_000
        )

      first_task = Task.async(fn -> first.(partition(key)) end)
      assert_receive :first_in, 1_000

      second_task = Task.async(fn -> second.(partition(key)) end)
      # The second is BLOCKED on the contended lease — it must NOT have entered yet.
      refute_receive :second_in, 200

      # Release the first; only now can the second acquire and enter.
      send(first_task.pid, :release_first)
      assert Task.await(first_task) == :converged
      assert_receive :second_in, 2_000
      assert Task.await(second_task) == :converged

      # Both released: the shared key is free.
      assert Memory.peek(key, ctx.lease_opts) == :free
    end

    test "disjoint keys do NOT serialize — both run concurrently", ctx do
      parent = self()

      mk = fn ->
        LeasedReconciler.wrap(
          fn p ->
            send(parent, {:in, p.key})
            # block until both have entered, proving concurrency
            receive do
              :go -> :converged
            end
          end,
          backend: ctx.backend,
          lease_opts: ctx.lease_opts
        )
      end

      a = Task.async(fn -> mk.().(partition("radius:lib/a.ex")) end)
      b = Task.async(fn -> mk.().(partition("radius:lib/b.ex")) end)

      # Both enter without waiting (disjoint keys, no contention).
      assert_receive {:in, "radius:lib/a.ex"}, 1_000
      assert_receive {:in, "radius:lib/b.ex"}, 1_000

      send(a.pid, :go)
      send(b.pid, :go)
      assert Task.await(a) == :converged
      assert Task.await(b) == :converged
    end
  end
end

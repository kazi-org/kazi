defmodule Kazi.Scheduler.OverlapPolicyTest do
  @moduledoc """
  T21.6 acceptance (ADR-0027 step 2), in-memory lease: a partition whose blast
  radius GROWS mid-run to overlap a sibling — disjoint at partition time —
  SERIALIZES on the now-shared key (one waits) rather than both editing the shared
  radius concurrently; a DISJOINT pair (no growth into a sibling) still runs free;
  every key a partition holds (its own + grown) is released on terminal, incl.
  crash.

  Hermetic: a real `Kazi.Coordination.Lease.Memory` store (the single-node
  default, NOT a stub) and an injected grow-aware inner. No NATS, no harness.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Kazi.Coordination.Lease
  alias Kazi.Coordination.Lease.Memory
  alias Kazi.Scheduler.OverlapPolicy

  setup do
    {:ok, store} = Memory.start_link()
    %{store: store, backend: Memory, lease_opts: [store: store]}
  end

  defp partition(key), do: %{key: key}

  describe "own-key lifecycle (composes with the LeasedReconciler intent)" do
    test "the partition's own key is HELD during the run and FREE after", ctx do
      key = "radius:lib/own.ex"
      test_pid = self()

      inner = fn {_p, _acquire_radius} ->
        send(test_pid, {:own_held?, Memory.peek(key, ctx.lease_opts)})
        :converged
      end

      reconciler =
        OverlapPolicy.wrap(inner, backend: ctx.backend, lease_opts: ctx.lease_opts)

      assert reconciler.(partition(key)) == :converged
      assert_received {:own_held?, {:ok, %Lease{key: ^key}}}
      assert Memory.peek(key, ctx.lease_opts) == :free
    end

    test "all dynamically-grown keys are released on terminal", ctx do
      own = "radius:lib/own.ex"
      grown = "radius:lib/grown.ex"

      inner = fn {_p, acquire_radius} ->
        assert acquire_radius.(grown) == :ok
        :converged
      end

      reconciler =
        OverlapPolicy.wrap(inner, backend: ctx.backend, lease_opts: ctx.lease_opts)

      assert reconciler.(partition(own)) == :converged
      # Both the own key and the grown key are freed.
      assert Memory.peek(own, ctx.lease_opts) == :free
      assert Memory.peek(grown, ctx.lease_opts) == :free
    end

    test "a raising reconciler still releases its whole lease-set as it unwinds", ctx do
      own = "radius:lib/own.ex"
      grown = "radius:lib/grown.ex"

      inner = fn {_p, acquire_radius} ->
        :ok = acquire_radius.(grown)
        raise "kaboom"
      end

      reconciler =
        OverlapPolicy.wrap(inner, backend: ctx.backend, lease_opts: ctx.lease_opts)

      capture_log(fn ->
        assert_raise RuntimeError, "kaboom", fn -> reconciler.(partition(own)) end
      end)

      assert Memory.peek(own, ctx.lease_opts) == :free
      assert Memory.peek(grown, ctx.lease_opts) == :free
    end
  end

  describe "DYNAMIC overlap: a partition grows to overlap a sibling — it SERIALIZES" do
    test "a partition growing into a key a sibling holds WAITS until the sibling releases",
         ctx do
      # Two partitions DISJOINT at partition time (distinct own keys), so both
      # acquire freely and run concurrently. Mid-run, the second GROWS into the
      # first's key — now it must wait for the first to release before editing the
      # shared radius.
      first_key = "radius:lib/first.ex"
      second_key = "radius:lib/second.ex"
      shared_key = first_key
      parent = self()

      # The first holds its own key (= the shared key) and blocks until released.
      first =
        OverlapPolicy.wrap(
          fn {_p, _acquire} ->
            send(parent, :first_in)

            receive do
              :release_first -> :converged
            end
          end,
          backend: ctx.backend,
          lease_opts: ctx.lease_opts,
          retry_interval_ms: 5
        )

      # The second runs free on its own key, then GROWS into the shared key. The
      # grow-acquire must block until the first releases.
      second =
        OverlapPolicy.wrap(
          fn {_p, acquire_radius} ->
            send(parent, :second_in)
            # Grow into the sibling's radius — this MUST serialize behind `first`.
            result = acquire_radius.(shared_key)
            send(parent, {:second_grew, result})
            :converged
          end,
          backend: ctx.backend,
          lease_opts: ctx.lease_opts,
          retry_interval_ms: 5,
          acquire_timeout_ms: 2_000
        )

      first_task = Task.async(fn -> first.(partition(first_key)) end)
      assert_receive :first_in, 1_000

      second_task = Task.async(fn -> second.(partition(second_key)) end)
      # The second ran free on its OWN key (disjoint at partition time)...
      assert_receive :second_in, 1_000
      # ...but its GROWTH into the shared radius BLOCKS — it must not complete the
      # grow-acquire while the first still holds the shared key.
      refute_receive {:second_grew, _}, 200

      # Release the first; only now can the second's growth acquire the shared key.
      send(first_task.pid, :release_first)
      assert Task.await(first_task) == :converged
      assert_receive {:second_grew, :ok}, 2_000
      assert Task.await(second_task) == :converged

      # Both released their whole lease-set.
      assert Memory.peek(first_key, ctx.lease_opts) == :free
      assert Memory.peek(second_key, ctx.lease_opts) == :free
    end

    test "a partition whose growth cannot acquire the contended key in time escalates",
         ctx do
      shared_key = "radius:lib/contended.ex"
      parent = self()

      holder =
        OverlapPolicy.wrap(
          fn {_p, _acquire} ->
            send(parent, :holder_in)

            receive do
              :release -> :converged
            end
          end,
          backend: ctx.backend,
          lease_opts: ctx.lease_opts
        )

      # The grower's own key is distinct; its GROWTH targets the held shared key
      # with a TINY acquire timeout, so it cannot take it and must escalate.
      grower =
        OverlapPolicy.wrap(
          fn {_p, acquire_radius} ->
            case acquire_radius.(shared_key) do
              {:error, :overlap_timeout} -> :stuck
              :ok -> :converged
            end
          end,
          backend: ctx.backend,
          lease_opts: ctx.lease_opts,
          retry_interval_ms: 2,
          acquire_timeout_ms: 30
        )

      holder_task = Task.async(fn -> holder.(partition(shared_key)) end)
      assert_receive :holder_in, 1_000

      # The grower cannot take the contended radius → escalates to :stuck (it must
      # NOT edit a radius it could not lease).
      assert grower.(partition("radius:lib/grower-own.ex")) == :stuck

      send(holder_task.pid, :release)
      assert Task.await(holder_task) == :converged
    end
  end

  describe "DISJOINT growth still runs FREE" do
    test "two partitions growing into DIFFERENT keys never wait on each other", ctx do
      parent = self()

      mk = fn own_key, grow_key ->
        OverlapPolicy.wrap(
          fn {_p, acquire_radius} ->
            send(parent, {:in, own_key})
            # Grow into a DISJOINT key — no sibling holds it, so no wait.
            :ok = acquire_radius.(grow_key)
            send(parent, {:grew, own_key})

            receive do
              :go -> :converged
            end
          end,
          backend: ctx.backend,
          lease_opts: ctx.lease_opts
        )
      end

      a =
        Task.async(fn ->
          mk.("radius:lib/a.ex", "radius:lib/a-grown.ex").(partition("radius:lib/a.ex"))
        end)

      b =
        Task.async(fn ->
          mk.("radius:lib/b.ex", "radius:lib/b-grown.ex").(partition("radius:lib/b.ex"))
        end)

      # Both enter AND grow without waiting (disjoint own + grown keys).
      assert_receive {:in, "radius:lib/a.ex"}, 1_000
      assert_receive {:in, "radius:lib/b.ex"}, 1_000
      assert_receive {:grew, "radius:lib/a.ex"}, 1_000
      assert_receive {:grew, "radius:lib/b.ex"}, 1_000

      send(a.pid, :go)
      send(b.pid, :go)
      assert Task.await(a) == :converged
      assert Task.await(b) == :converged
    end
  end
end

defmodule Kazi.Coordination.Lease.MemoryTest do
  @moduledoc """
  The in-memory `Kazi.Coordination.Lease` backend (T3.1a).

  The bulk of the contract — CAS mutual exclusion, injected TTL expiry, renew,
  idempotent release, peek — is asserted by the shared, backend-agnostic suite
  `Kazi.Coordination.LeaseContract`, the SAME suite the real NATS backend reuses
  (T3.1b). The tests written out here are the few properties the shared suite
  cannot express because they are specific to this backend: the Agent makes the
  CAS *atomic under real concurrency*, and a store handle is required.
  """

  use ExUnit.Case, async: true

  alias Kazi.Coordination.Lease
  alias Kazi.Coordination.Lease.Memory

  # The shared conformance suite, instantiated against the in-memory backend with
  # a fresh store per test. This is the entry point T3.1b mirrors for NATS.
  use Kazi.Coordination.LeaseContract,
    backend: Kazi.Coordination.Lease.Memory,
    setup_lease_backend: fn ->
      {:ok, store} = Memory.start_link()
      [store: store]
    end

  describe "atomic CAS under concurrency (backend-specific)" do
    test "exactly one of many racing acquirers wins a free key" do
      {:ok, store} = Memory.start_link()
      opts = [store: store, now_ms: 0]

      results =
        1..50
        |> Task.async_stream(
          fn n -> Memory.acquire("hot", "holder-#{n}", 10_000, opts) end,
          max_concurrency: 50,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      winners = Enum.filter(results, &match?({:ok, _}, &1))
      losers = Enum.filter(results, &match?({:error, :held}, &1))

      assert length(winners) == 1
      assert length(losers) == 49
    end
  end

  describe "store handle (backend-specific)" do
    test "a missing :store handle raises a clear ArgumentError" do
      assert_raise ArgumentError, ~r/requires a :store handle/, fn ->
        Memory.acquire("k", "a", 1_000, now_ms: 0)
      end
    end

    test "separate stores are isolated" do
      {:ok, store_a} = Memory.start_link()
      {:ok, store_b} = Memory.start_link()

      assert {:ok, _} = Memory.acquire("k", "a", 1_000, store: store_a, now_ms: 0)

      # The same key in a different store is free.
      assert {:ok, %Lease{holder: "b"}} =
               Memory.acquire("k", "b", 1_000, store: store_b, now_ms: 0)
    end
  end
end

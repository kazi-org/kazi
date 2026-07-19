defmodule Kazi.Coordination.LeaseContract do
  @moduledoc """
  The shared, backend-agnostic behaviour-conformance suite for
  `Kazi.Coordination.Lease` (T3.1a, ADR-0006; UC-013).

  `use Kazi.Coordination.LeaseContract` injects the full set of contract tests
  into a test module; each test asks the host for a fresh backend + per-call opts
  and exercises one clause of the lease contract (CAS mutual exclusion, injected
  TTL expiry, renew, idempotent release, peek). This is the SAME suite the real
  NATS JetStream KV backend reuses (T3.1b) — it is deliberately written against
  the `Kazi.Coordination.Lease` behaviour and an injected clock, with no
  knowledge of how any backend stores leases.

  ## Reusing it

  The host module supplies two callbacks via `use` options, then `use`s this
  module:

    * `backend: module` — the module implementing `Kazi.Coordination.Lease`.
    * `setup_lease_backend: fn -> keyword() end` — a zero-arity fn run per test
      that provisions a *fresh* store and returns the per-call `opts` (e.g.
      `[store: handle]`) that every contract call is made with. The contract adds
      the injected clock (`:now_ms`) on top of these opts, so the backend MUST
      honour `Kazi.Coordination.Lease.now_ms/1` for expiry to be deterministic.

  The in-memory default wires it like this (and T3.1b will mirror it, swapping the
  backend + an `NATS_URL`-gated store):

      defmodule Kazi.Coordination.Lease.MemoryContractTest do
        use ExUnit.Case, async: true

        use Kazi.Coordination.LeaseContract,
          backend: Kazi.Coordination.Lease.Memory,
          setup_lease_backend: fn ->
            {:ok, store} = Kazi.Coordination.Lease.Memory.start_link()
            [store: store]
          end
      end

  ## Determinism

  Every contract test drives a **virtual clock** by passing an explicit `:now_ms`
  on each call (never a wall clock), so TTL boundaries are exact and the suite is
  hermetic — no `Process.sleep`, no real time, no network. A backend that reads a
  wall clock in an expiry path instead of `Kazi.Coordination.Lease.now_ms/1` will
  fail the expiry tests here, which is the point.
  """

  @doc false
  defmacro __using__(opts) do
    backend = Keyword.fetch!(opts, :backend)
    # The setup fn is injected as raw AST (not via bind_quoted): an anonymous
    # function cannot be escaped into a module attribute, so it is spliced
    # directly into the generated `setup` block where it is simply called.
    setup_fun = Keyword.fetch!(opts, :setup_lease_backend)

    quote do
      @lease_backend unquote(backend)

      alias Kazi.Coordination.Lease

      setup do
        {:ok, base_opts: unquote(setup_fun).()}
      end

      # Build the per-call opts: the backend's provisioned opts (e.g. the store
      # handle) plus an explicit virtual-clock reading. Every contract call goes
      # through this so the clock is injected, never read from the wall.
      defp lease_opts(base_opts, now_ms) do
        Keyword.put(base_opts, :now_ms, now_ms)
      end

      describe "acquire (CAS mutual exclusion)" do
        test "a free key is acquired by the first holder", %{base_opts: base} do
          assert {:ok, %Lease{key: "k", holder: "a", revision: rev}} =
                   @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))

          assert is_integer(rev) and rev >= 1
        end

        test "a second, different holder loses while the first holds it", %{base_opts: base} do
          assert {:ok, _lease} = @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))

          # Well within the first holder's TTL — the key is held.
          assert {:error, :held} =
                   @lease_backend.acquire("k", "b", 1_000, lease_opts(base, 500))
        end

        test "the same holder re-acquiring refreshes and bumps the revision", %{base_opts: base} do
          assert {:ok, %Lease{revision: r1, expires_at_ms: e1}} =
                   @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))

          assert {:ok, %Lease{revision: r2, expires_at_ms: e2}} =
                   @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 100))

          assert r2 > r1
          # Re-acquire extends the TTL from the new `now`.
          assert e2 > e1
          assert e2 == 100 + 1_000
        end

        test "distinct keys do not contend (disjoint lease-sets run concurrently)",
             %{base_opts: base} do
          assert {:ok, _} = @lease_backend.acquire("k1", "a", 1_000, lease_opts(base, 0))
          assert {:ok, _} = @lease_backend.acquire("k2", "b", 1_000, lease_opts(base, 0))
        end
      end

      describe "TTL expiry (injected clock)" do
        test "the key is still held one ms before expiry", %{base_opts: base} do
          assert {:ok, _} = @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))

          assert {:error, :held} =
                   @lease_backend.acquire("k", "b", 1_000, lease_opts(base, 999))
        end

        test "expiry frees the key for another holder at the TTL boundary",
             %{base_opts: base} do
          assert {:ok, _} = @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))

          # At exactly now+ttl the first lease has expired; b can take it.
          assert {:ok, %Lease{holder: "b"}} =
                   @lease_backend.acquire("k", "b", 1_000, lease_opts(base, 1_000))
        end

        test "an expired holder's revision does not match the new acquisition",
             %{base_opts: base} do
          assert {:ok, %Lease{revision: r1} = stale} =
                   @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))

          assert {:ok, %Lease{revision: r2}} =
                   @lease_backend.acquire("k", "b", 1_000, lease_opts(base, 1_000))

          assert r2 > r1
          # The expired holder cannot renew or release the re-acquired key.
          assert {:error, :not_held} =
                   @lease_backend.renew(stale, 1_000, lease_opts(base, 1_100))

          assert :ok = @lease_backend.release(stale, lease_opts(base, 1_100))
          # b still holds it after the stale release no-op.
          assert {:ok, %Lease{holder: "b"}} =
                   @lease_backend.peek("k", lease_opts(base, 1_100))
        end
      end

      describe "renew" do
        test "renew extends the TTL and bumps the revision", %{base_opts: base} do
          assert {:ok, %Lease{revision: r1} = lease} =
                   @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))

          assert {:ok, %Lease{revision: r2, expires_at_ms: e2}} =
                   @lease_backend.renew(lease, 1_000, lease_opts(base, 500))

          assert r2 > r1
          assert e2 == 500 + 1_000
        end

        test "a renewed lease keeps the key held past the original expiry",
             %{base_opts: base} do
          assert {:ok, lease} = @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))
          assert {:ok, _renewed} = @lease_backend.renew(lease, 1_000, lease_opts(base, 900))

          # Original expiry was 1_000; renewed expiry is 1_900. Still held at 1_500.
          assert {:error, :held} =
                   @lease_backend.acquire("k", "b", 1_000, lease_opts(base, 1_500))
        end

        test "renewing a superseded lease fails", %{base_opts: base} do
          assert {:ok, stale} = @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))
          # Same holder re-acquires, advancing the revision past `stale`.
          assert {:ok, _current} = @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 100))

          assert {:error, :not_held} =
                   @lease_backend.renew(stale, 1_000, lease_opts(base, 200))
        end

        test "renewing an expired lease fails", %{base_opts: base} do
          assert {:ok, lease} = @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))

          assert {:error, :not_held} =
                   @lease_backend.renew(lease, 1_000, lease_opts(base, 1_000))
        end
      end

      describe "release" do
        test "release frees the key for another holder", %{base_opts: base} do
          assert {:ok, lease} = @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))
          assert :ok = @lease_backend.release(lease, lease_opts(base, 100))

          # Freed well before the TTL — b takes it immediately.
          assert {:ok, %Lease{holder: "b"}} =
                   @lease_backend.acquire("k", "b", 1_000, lease_opts(base, 100))
        end

        test "release is idempotent (releasing twice is still :ok)", %{base_opts: base} do
          assert {:ok, lease} = @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))
          assert :ok = @lease_backend.release(lease, lease_opts(base, 100))
          assert :ok = @lease_backend.release(lease, lease_opts(base, 200))
        end

        test "a stale holder's release does not free the current holder's key",
             %{base_opts: base} do
          assert {:ok, stale} = @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))
          assert :ok = @lease_backend.release(stale, lease_opts(base, 100))
          # b acquires the now-free key.
          assert {:ok, _b_lease} = @lease_backend.acquire("k", "b", 1_000, lease_opts(base, 100))

          # The stale lease releasing again must NOT free b's key.
          assert :ok = @lease_backend.release(stale, lease_opts(base, 150))

          assert {:ok, %Lease{holder: "b"}} =
                   @lease_backend.peek("k", lease_opts(base, 150))
        end
      end

      describe "peek" do
        test "peek reports the live holder", %{base_opts: base} do
          assert {:ok, _} = @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))

          assert {:ok, %Lease{holder: "a"}} =
                   @lease_backend.peek("k", lease_opts(base, 500))
        end

        test "peek reports a free key as :free (never acquired)", %{base_opts: base} do
          assert :free = @lease_backend.peek("never", lease_opts(base, 0))
        end

        test "peek reports an expired key as :free", %{base_opts: base} do
          assert {:ok, _} = @lease_backend.acquire("k", "a", 1_000, lease_opts(base, 0))
          assert :free = @lease_backend.peek("k", lease_opts(base, 1_000))
        end
      end
    end
  end
end

defmodule Kazi.Scheduler.LeasedReconciler do
  @moduledoc """
  Per-partition **lease lifecycle** around a reconciler (T21.3, ADR-0027): each
  partition acquires its `Kazi.Coordination.PartitionLease` ON START and releases
  it ON TERMINAL — including on crash.

  ADR-0027 step 2: the scheduler **leases each partition for the life of its
  run**. Disjoint partitions hold distinct keys and run in parallel; residual
  mid-run overlap (two partitions deriving the SAME blast-radius key) SERIALIZES
  on the lease — the second acquirer loses the CAS and waits until the first
  releases. On a single machine this uses the IN-MEMORY backend
  (`Kazi.Coordination.Lease.Memory`), NATS-free; the NATS backend (ADR-0004) is
  config-selected for multi-node and is NOT required here.

  This module is the SEAM that wraps the scheduler's injectable reconciler
  (`t:Kazi.Scheduler.reconciler/0`) without changing it: `wrap/2` returns a new
  reconciler that, per partition,

    1. **acquires** the lease keyed by the partition's stable `:key`
       (`Kazi.Coordination.PartitionLease.lease_key/1`), blocking-with-retry while
       a different holder owns an overlapping key (so overlap serializes); then
    2. runs the wrapped reconciler; then
    3. **releases** the lease in an `after` so it is freed on EVERY exit path —
       normal terminal, an `{:error, _}` return, or a crash/raise. A crash still
       releases because the `try/after` runs as the process unwinds; the lease is
       never left dangling for the partition's whole TTL.

  ## Holder identity (why overlap serializes)

  Each partition acquires under a holder UNIQUE to that partition (its lease key
  plus a per-run nonce), so two DIFFERENT partitions that nonetheless derive the
  SAME key are different holders contending on one lease — exactly the residual
  overlap ADR-0027 says must serialize. (A re-acquire by the *same* holder
  refreshes rather than blocks; that path is not exercised here since each
  wrapped run is one holder.)

  ## Hermetic + injectable

  The backend, store, TTL, and clock are all injected (the in-memory backend's
  `:store` handle is mandatory). Tests drive a real `Kazi.Coordination.Lease.Memory`
  store and a virtual clock; production wiring passes the single-node in-memory
  store (or the NATS backend behind config). No clock is read here that a caller
  cannot control, matching the lease contract.
  """

  alias Kazi.Coordination.Lease
  alias Kazi.Coordination.LeaseTable

  @default_ttl_ms 60_000
  @default_acquire_timeout_ms 30_000
  @default_retry_interval_ms 10

  @typedoc """
  A function projecting a partition onto its lease key. Defaults to
  `Kazi.Coordination.PartitionLease.lease_key/1` over a partition carrying a
  `:key` field, so a `Kazi.Scheduler.Partitioner` entry leases on its
  blast-radius key.
  """
  @type key_fun :: (term() -> Lease.key())

  @doc """
  Wraps `inner` so each partition holds its lease for the life of its reconcile.

  Returns a new `t:Kazi.Scheduler.reconciler/0`. Per partition it acquires the
  partition's lease (blocking-with-retry while a different holder owns it),
  invokes `inner`, and releases the lease in an `after` — so the lease is freed on
  a normal terminal, an error return, and a crash alike. The wrapped reconciler's
  status (or a crash) propagates unchanged; this seam only brackets it with the
  lease.

  ## Options

    * `:backend` — the `Kazi.Coordination.Lease` backend module (required;
      typically `Kazi.Coordination.Lease.Memory` on a single node).
    * `:lease_opts` — opts forwarded to every backend call (the in-memory backend
      needs its `:store` handle here; a virtual clock's `:now_ms`/`:now_fn` may
      ride here too).
    * `:key_fun` — projects a partition onto its lease key (default
      `Kazi.Coordination.PartitionLease.lease_key/1`).
    * `:ttl_ms` — lease TTL in ms (default `#{@default_ttl_ms}`). Generous: a run
      outlasting its TTL is a deepening concern (renewal, T21.10), not this
      skeleton's; the lease is released on terminal regardless.
    * `:acquire_timeout_ms` — how long to block waiting for a contended lease
      before giving up (default `#{@default_acquire_timeout_ms}`). A partition
      that cannot acquire in time reconciles to `:stuck` (it never converged).
    * `:retry_interval_ms` — poll interval while a lease is contended (default
      `#{@default_retry_interval_ms}`).
    * `:lease_table` — the readable native-lease registry to publish the held lease
      into for the duration of the run (default `Kazi.Coordination.LeaseTable`), so
      the NATS-free dashboard (`/leases`) can render the live lease map. Best-effort:
      a no-op when the table is not running (a hermetic test, the escript), so this
      never couples the scheduler to the web tree.
  """
  @spec wrap(Kazi.Scheduler.reconciler(), keyword()) :: Kazi.Scheduler.reconciler()
  def wrap(inner, opts) when is_function(inner, 1) and is_list(opts) do
    backend = Keyword.fetch!(opts, :backend)
    lease_opts = Keyword.get(opts, :lease_opts, [])
    key_fun = Keyword.get(opts, :key_fun, &default_key/1)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    acquire_timeout = Keyword.get(opts, :acquire_timeout_ms, @default_acquire_timeout_ms)
    retry_interval = Keyword.get(opts, :retry_interval_ms, @default_retry_interval_ms)
    lease_table = Keyword.get(opts, :lease_table, LeaseTable)

    fn partition ->
      key = key_fun.(partition)
      holder = holder_for(key)

      case acquire(backend, key, holder, ttl_ms, lease_opts, acquire_timeout, retry_interval) do
        {:ok, lease} ->
          # Publish the held lease so the NATS-free dashboard can read it; forgotten
          # on terminal alongside the release. Best-effort (no-op when absent).
          LeaseTable.record(lease, lease_table)

          try do
            inner.(partition)
          after
            # Release on EVERY exit path — normal, error return, or crash. The
            # `after` runs as the process unwinds, so a raising reconciler still
            # frees its lease rather than holding it for the whole TTL.
            backend.release(lease, lease_opts)
            LeaseTable.forget(lease, lease_table)
          end

        :timeout ->
          # Could not take a contended lease in time — never ran, never
          # converged. The collective fold treats :stuck as escalate.
          :stuck
      end
    end
  end

  # Acquire with blocking-retry: a different holder owning the key returns
  # {:error, :held}, so we poll until it releases (overlap serializes) or the
  # acquire timeout elapses. The clock is whatever `lease_opts` injects, so a
  # virtual-clock test still observes the held→free transition.
  defp acquire(backend, key, holder, ttl_ms, lease_opts, timeout_remaining, retry_interval) do
    case backend.acquire(key, holder, ttl_ms, lease_opts) do
      {:ok, lease} ->
        {:ok, lease}

      {:error, :held} when timeout_remaining > 0 ->
        Process.sleep(retry_interval)

        acquire(
          backend,
          key,
          holder,
          ttl_ms,
          lease_opts,
          timeout_remaining - retry_interval,
          retry_interval
        )

      {:error, :held} ->
        :timeout
    end
  end

  # A holder UNIQUE to this wrapped run so two distinct partitions that derive the
  # same key contend (serialize) rather than both being treated as the same
  # party. The key prefix keeps it legible; the nonce makes it per-run distinct.
  defp holder_for(key) do
    nonce = :erlang.unique_integer([:positive, :monotonic])
    "kazi.partition:" <> key <> ":" <> Integer.to_string(nonce)
  end

  # Default key projection: a partition that carries a `:key` (a
  # `Kazi.Scheduler.Partitioner` entry or a `Kazi.Partition`) leases on it.
  defp default_key(%{key: key}) when is_binary(key), do: key
end

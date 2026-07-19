defmodule Kazi.Scheduler.OverlapPolicy do
  @moduledoc """
  Dynamic blast-radius **overlap policy** (T21.6, ADR-0027 step 2): serialize a
  partition whose radius GROWS mid-run to overlap a sibling that was disjoint at
  partition time.

  `Kazi.Scheduler.LeasedReconciler` (T21.3) already handles the STATIC case:
  partitions that share a blast-radius key at partition time hold the SAME
  `Kazi.Coordination.PartitionLease` key and serialize on the lease — the second
  acquirer loses the CAS and waits. But ADR-0027 step 2 also names the DYNAMIC
  case: a partition's edits can EXPAND its radius mid-run so it now touches a file
  a sibling — disjoint at partition time, holding a different key — is already
  editing. Two partitions then concurrently edit a SHARED radius, and one's
  growth can corrupt the other's converged work (the very thing partitioning
  exists to prevent).

  This module is the seam that closes that gap. It wraps a reconciler so the inner
  reconcile can REPORT the radius it actually touched (the keys it discovers it
  needs as it edits), and before it proceeds to edit those newly-overlapping keys
  it ACQUIRES a lease on each — exactly like the partition's own key. A key a
  sibling already holds is CONTENDED: the acquire loses the CAS and the partition
  WAITS until the sibling releases (serialize), rather than both editing the
  shared radius concurrently. A partition whose growth touches only free keys
  proceeds without waiting (a disjoint pair still runs free).

  ## How growth is detected (the lease acquire IS the detector)

  The overlap detector is NOT a separate watcher; it is the lease acquire itself.
  The in-memory lease (`Kazi.Coordination.Lease.Memory`) is the single shared
  arbiter of "who is editing this radius now." When a partition grows into a new
  key, it tries to acquire that key under its OWN holder; the CAS tells it
  whether a sibling holds it:

    * **free / held-by-self** ⇒ the growth does not overlap a live sibling — take
      the key and proceed (a disjoint pair keeps running free);
    * **held by a different holder** ⇒ the growth NOW overlaps a sibling that was
      disjoint at partition time — block-with-retry until the sibling releases,
      THEN proceed (serialize the overlapping pair). This is the new-overlap case
      ADR-0027 step 2 requires to serialize.

  Because a sibling holds its OWN partition key for the life of its run
  (`LeasedReconciler` / this seam's own-key acquire), a partition growing INTO the
  sibling's original key is detected the same way: the acquire on that key
  conflicts with the sibling's long-held lease.

  ## The grow-aware inner contract

  `wrap/2` wraps a reconciler whose inner fn is grow-aware: it is handed an
  `acquire_radius` function and calls it with each NEW key it discovers it needs
  BEFORE editing that radius. The call blocks (serializes) while a sibling holds
  the key and returns once the key is held (or the acquire times out, in which
  case the partition cannot safely grow into the contended radius and escalates
  to `:stuck` — it never converged, and it must NOT edit a radius it could not
  lease). Every dynamically-acquired key is released on terminal (incl. crash) in
  an `after`, alongside the partition's own key, so growth never leaks a lease.

  This composes with `LeasedReconciler`'s intent: this seam leases the partition's
  ORIGINAL key for the whole run AND each key the partition GROWS into, with one
  holder identity per run, so the partition's own original key and its grown keys
  are one consistent set it holds while editing and frees on terminal.

  ## Re-dispatch vs. wait

  ADR-0027 step 2 says "serialize the overlapping pair (or re-partition)." This
  module implements SERIALIZE (the in-loop wait): the growing partition defers to
  the sibling holding the contended radius and proceeds once it frees. That is the
  minimal, deadlock-free policy on a single node — the wait is bounded by
  `:acquire_timeout_ms`, and a partition that times out escalates to `:stuck`
  rather than corrupting the sibling. Re-partitioning (recomputing partitions from
  the grown radius and re-dispatching) is the heavier alternative
  (`Kazi.Scheduler.Integration` already re-dispatches on a residual MERGE
  conflict, T21.5); this seam handles the in-run overlap before edits land.

  ## Hermetic + injectable

  The backend, store, TTL, and clock are injected exactly as in
  `LeasedReconciler` — tests drive a real `Kazi.Coordination.Lease.Memory` store
  (the single-node default, not a stub) and an injected inner reconciler. No NATS,
  no harness.
  """

  alias Kazi.Coordination.Lease

  @default_ttl_ms 60_000
  @default_acquire_timeout_ms 30_000
  @default_retry_interval_ms 10

  @typedoc """
  The grow-aware inner reconciler. Unlike a bare `t:Kazi.Scheduler.reconciler/0`,
  it is handed `{partition, acquire_radius}` where `acquire_radius` is a
  `t:acquire_radius/0`: the inner calls it with each NEW blast-radius key it
  discovers it needs before editing that radius. The call serializes the partition
  behind any sibling holding the key.
  """
  @type grow_aware ::
          ({partition :: term(), acquire_radius()} ->
             Kazi.Scheduler.partition_status() | {:error, term()})

  @typedoc """
  The radius-acquire seam handed to a grow-aware inner. Called with a key the
  partition has grown into; returns `:ok` once the key is held by this partition
  (after waiting out any sibling that held it), or `{:error, :overlap_timeout}`
  when a sibling held the contended key past the acquire timeout (the partition
  cannot safely grow into that radius).
  """
  @type acquire_radius :: (Lease.key() -> :ok | {:error, :overlap_timeout})

  @doc """
  Wraps a grow-aware `inner` so a partition that grows into a sibling's radius
  SERIALIZES on the contended key rather than editing it concurrently.

  Returns a `t:Kazi.Scheduler.reconciler/0`. Per partition it acquires the
  partition's OWN key (its `key_fun` projection), then invokes `inner` with an
  `acquire_radius` fn; each new key the inner grows into is acquired the same way
  — free keys proceed immediately (disjoint growth runs free), a key a sibling
  holds blocks-with-retry until released (the overlapping pair serializes). Every
  key the partition holds (its own + every grown key) is released on terminal,
  including on crash, in an `after`.

  If a grown key cannot be acquired within `:acquire_timeout_ms` (a sibling held
  it the whole time), `acquire_radius` returns `{:error, :overlap_timeout}` so the
  inner can escalate; a partition that cannot lease a radius it needs converges to
  `:stuck` (it must not edit an unleased shared radius).

  ## Options

  Same shape as `Kazi.Scheduler.LeasedReconciler.wrap/2`:

    * `:backend` — the `Kazi.Coordination.Lease` backend module (required;
      `Kazi.Coordination.Lease.Memory` on a single node);
    * `:lease_opts` — opts forwarded to every backend call (the in-memory backend
      needs its `:store` handle here; a virtual clock may ride here too);
    * `:key_fun` — projects the partition onto its OWN starting key (default a
      `:key` field, a `Kazi.Scheduler.Partitioner` entry);
    * `:ttl_ms`, `:acquire_timeout_ms`, `:retry_interval_ms` — lease TTL, contended
      acquire timeout, and poll interval (defaults
      `#{@default_ttl_ms}`/`#{@default_acquire_timeout_ms}`/`#{@default_retry_interval_ms}`).
  """
  @spec wrap(grow_aware(), keyword()) :: Kazi.Scheduler.reconciler()
  def wrap(inner, opts) when is_function(inner, 1) and is_list(opts) do
    backend = Keyword.fetch!(opts, :backend)
    lease_opts = Keyword.get(opts, :lease_opts, [])
    key_fun = Keyword.get(opts, :key_fun, &default_key/1)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    acquire_timeout = Keyword.get(opts, :acquire_timeout_ms, @default_acquire_timeout_ms)
    retry_interval = Keyword.get(opts, :retry_interval_ms, @default_retry_interval_ms)

    fn partition ->
      key = key_fun.(partition)
      # A holder UNIQUE to this run identifies every key this partition holds (its
      # own + every grown key), so a sibling deriving the same key is a DIFFERENT
      # holder and contends (serializes).
      holder = holder_for(key)

      # `held` accumulates every lease this partition currently holds so they are
      # all released on terminal (incl. crash). An Agent gives the grow-aware inner
      # a place to record keys it acquires from inside its own process.
      {:ok, held} = Agent.start_link(fn -> [] end)

      acquire_radius =
        build_acquire_radius(
          held,
          backend,
          holder,
          ttl_ms,
          lease_opts,
          acquire_timeout,
          retry_interval
        )

      try do
        # Acquire the partition's OWN key first (blocking-with-retry on residual
        # STATIC overlap, exactly like LeasedReconciler), recording it in `held`.
        case acquire_radius.(key) do
          :ok ->
            inner.({partition, acquire_radius})

          {:error, :overlap_timeout} ->
            # Could not even take the partition's own key — a sibling holds it the
            # whole time. Never ran, never converged.
            :stuck
        end
      after
        # Release EVERY key this partition acquired (its own + all grown keys), on
        # every exit path — normal, error return, or crash. The `after` runs as the
        # process unwinds, so a raising reconciler frees its whole lease-set.
        held
        |> Agent.get(& &1)
        |> Enum.each(fn lease -> backend.release(lease, lease_opts) end)

        Agent.stop(held)
      end
    end
  end

  # Build the radius-acquire seam closed over this run's holder + `held` accumulator.
  # Each call acquires `key` under our holder (block-with-retry while a sibling
  # holds it), records the held lease so it is released on terminal, and returns
  # :ok; a sibling that holds the key past the timeout yields {:error,
  # :overlap_timeout}.
  defp build_acquire_radius(
         held,
         backend,
         holder,
         ttl_ms,
         lease_opts,
         acquire_timeout,
         retry_interval
       ) do
    fn key ->
      case acquire(backend, key, holder, ttl_ms, lease_opts, acquire_timeout, retry_interval) do
        {:ok, lease} ->
          # Record the lease so it is released on terminal. A re-acquire of the same
          # key by this same holder refreshes it; keep the latest lease only.
          Agent.update(held, fn leases -> [lease | reject_key(leases, key)] end)
          :ok

        :timeout ->
          {:error, :overlap_timeout}
      end
    end
  end

  defp reject_key(leases, key), do: Enum.reject(leases, &(&1.key == key))

  # Acquire with blocking-retry: a different holder owning the key returns
  # {:error, :held}, so we poll until it releases (overlap serializes) or the
  # acquire timeout elapses. Identical to LeasedReconciler's wait; the clock is
  # whatever `lease_opts` injects.
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

  # A holder UNIQUE to this wrapped run (so two distinct partitions that derive the
  # same key contend rather than being treated as the same party), shared across
  # every key this partition holds.
  defp holder_for(key) do
    nonce = :erlang.unique_integer([:positive, :monotonic])
    "kazi.partition:" <> key <> ":" <> Integer.to_string(nonce)
  end

  # Default key projection: a partition that carries a `:key` (a Partitioner entry
  # or a Kazi.Partition) leases on it.
  defp default_key(%{key: key}) when is_binary(key), do: key
end

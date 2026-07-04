defmodule Kazi.Coordination.Lease.Memory do
  @moduledoc """
  The in-process `Kazi.Coordination.Lease` backend: the **real single-node
  default**, and the test double for the shared conformance suite (T3.1a,
  ADR-0006; UC-013).

  This is not a stub. Within one BEAM node it is a correct, concurrency-safe lease
  store: a `GenServer` holds the `key => %Lease{}` map, and every mutation
  (acquire/renew/release) runs inside one server call, so the compare-and-set is
  **atomic** — two processes racing to acquire the same free key serialize
  through the server and exactly one wins. The NATS JetStream KV backend (T3.1b)
  replaces this only when work must coordinate *across* nodes; on a single node
  this backend is the production path, not a placeholder.

  ## Instance, not global

  A backend is a running server referenced by a `{__MODULE__, pid}` tuple, passed
  per call as the `:store` option. Nothing is global: each store is independent,
  so tests (and concurrent goals) are isolated without naming collisions, and the
  conformance suite spins up a fresh store per test.

      {:ok, store} = Kazi.Coordination.Lease.Memory.start_link()
      backend = Kazi.Coordination.Lease.Memory
      {:ok, lease} = backend.acquire("blast:lib/a.ex", "agent-1", 30_000, store: store, now_ms: 0)

  ## Injected clock

  Time is taken from `opts` via `Kazi.Coordination.Lease.now_ms/1` (`:now_ms` /
  `:now_fn`) and never read from a wall clock inside an expiry decision, so TTL
  expiry is deterministic under the conformance suite's virtual clock. Stored
  leases carry an absolute `expires_at_ms`; the free/held test is a pure
  comparison (`Kazi.Coordination.Lease.expired?/2`) against the supplied `now_ms`.

  ## CAS semantics

    * **acquire** — succeeds when the key is free *at `now_ms`* (never held, or the
      holder's lease expired) or already held by the *same* holder (refresh);
      bumps the revision. A different unexpired holder ⇒ `{:error, :held}`.
    * **renew / release** — act only when the presented lease is the *current*
      revision and not expired; a stale lease (the key moved on) ⇒
      `{:error, :not_held}` for renew, a silent no-op (`:ok`) for release.

  ## Holder-process monitoring (M8, deep-review-001)

  `acquire/4` is called from the process that will hold the lease, and this
  server MONITORS that process (`self()` at the call site) for the life of the
  lease. If the holder process dies WITHOUT releasing — including via an
  untrappable `Process.exit(pid, :kill)`, which skips a `try/after`'s release
  entirely (`Kazi.Scheduler.LeasedReconciler`'s brutal-kill / self-kill cases) —
  the server auto-releases the key on the `:DOWN`, so a sibling partition
  contending on the same blast-radius key is never blocked until the TTL simply
  because the holder was killed rather than exiting cleanly. A normal
  `release/2` demonitors, so a clean exit never leaves a stray monitor. `renew/3`
  never changes who is being watched — it is always called by the SAME process
  that acquired the lease, so the existing monitor is left untouched.
  """

  @behaviour Kazi.Coordination.Lease

  use GenServer

  alias Kazi.Coordination.Lease

  @typedoc "An opaque handle to a running store: the module-tagged server pid."
  @type store :: {__MODULE__, pid()}

  @doc """
  Starts a fresh, empty lease store and returns `{:ok, store_handle}`.

  The handle is the `{__MODULE__, pid}` tuple passed back per call as `:store`.
  Accepts standard `GenServer.start_link/3` options (e.g. `:name`) under `opts`.
  """
  @spec start_link(keyword()) :: {:ok, store()} | {:error, term()}
  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, :ok, opts) do
      {:ok, pid} -> {:ok, {__MODULE__, pid}}
      {:error, _reason} = error -> error
    end
  end

  @impl Lease
  def acquire(key, holder, ttl_ms, opts)
      when is_binary(key) and is_binary(holder) and is_integer(ttl_ms) and ttl_ms > 0 do
    pid = store_pid(opts)
    now = Lease.now_ms(opts)
    # M8: the CALLING process is the holder, monitored for auto-release on death.
    GenServer.call(pid, {:acquire, key, holder, ttl_ms, now, self()})
  end

  @impl Lease
  def renew(%Lease{} = lease, ttl_ms, opts) when is_integer(ttl_ms) and ttl_ms > 0 do
    pid = store_pid(opts)
    now = Lease.now_ms(opts)
    GenServer.call(pid, {:renew, lease, ttl_ms, now})
  end

  @impl Lease
  def release(%Lease{} = lease, opts) do
    pid = store_pid(opts)
    now = Lease.now_ms(opts)
    GenServer.call(pid, {:release, lease, now})
  end

  @impl Lease
  def peek(key, opts) when is_binary(key) do
    pid = store_pid(opts)
    now = Lease.now_ms(opts)
    GenServer.call(pid, {:peek, key, now})
  end

  # =============================================================================
  # Server
  # =============================================================================

  # State: the live `key => %Lease{}` map, plus the bookkeeping M8 needs to
  # auto-release on a dead holder — `monitors: %{ref => key}` (resolve a :DOWN
  # to the key it guards) and `holder_refs: %{key => ref}` (demonitor the RIGHT
  # ref on a normal release/re-acquire, never a stale one).
  @impl GenServer
  def init(:ok) do
    {:ok, %{leases: %{}, monitors: %{}, holder_refs: %{}}}
  end

  @impl GenServer
  def handle_call({:acquire, key, holder, ttl_ms, now, holder_pid}, _from, state) do
    expires_at = now + ttl_ms

    case live_lease(state.leases, key, now) do
      # Free at `now` (unheld or expired) — or held by us: mint/refresh, watching
      # the CALLING process (a re-acquire may be a different process presenting
      # the same holder string; the newest caller is who now truly holds it).
      nil ->
        {lease, state} = mint_and_monitor(state, key, holder, expires_at, holder_pid)
        {:reply, {:ok, lease}, state}

      %Lease{holder: ^holder} ->
        {lease, state} = mint_and_monitor(state, key, holder, expires_at, holder_pid)
        {:reply, {:ok, lease}, state}

      # A different, unexpired holder owns it.
      %Lease{} ->
        {:reply, {:error, :held}, state}
    end
  end

  def handle_call(
        {:renew, %Lease{key: key, holder: holder, revision: revision}, ttl_ms, now},
        _from,
        state
      ) do
    expires_at = now + ttl_ms

    case live_lease(state.leases, key, now) do
      # Still the current, unexpired lease we hold — extend + bump revision.
      # renew/3 is always called by the SAME process that acquired, so the
      # existing monitor on this key is still watching the right pid; leave it.
      %Lease{holder: ^holder, revision: ^revision} ->
        renewed = %Lease{
          key: key,
          holder: holder,
          revision: revision + 1,
          expires_at_ms: expires_at
        }

        {:reply, {:ok, renewed}, %{state | leases: Map.put(state.leases, key, renewed)}}

      # Superseded (revision moved on / re-acquired / expired / released).
      _other ->
        {:reply, {:error, :not_held}, state}
    end
  end

  def handle_call(
        {:release, %Lease{key: key, holder: holder, revision: revision}, now},
        _from,
        state
      ) do
    case live_lease(state.leases, key, now) do
      # We are the current holder — free the key and stop watching it.
      %Lease{holder: ^holder, revision: ^revision} ->
        {:reply, :ok, forget_key(state, key)}

      # Already free, expired, or superseded — releasing is a no-op.
      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:peek, key, now}, _from, state) do
    result =
      case live_lease(state.leases, key, now) do
        %Lease{} = lease -> {:ok, lease}
        nil -> :free
      end

    {:reply, result, state}
  end

  # M8 (deep-review-001): the holder process died — auto-release its lease so a
  # sibling contending on the same key does not wait out the whole TTL just
  # because the holder was killed (brutal-kill, self-kill) rather than exiting
  # cleanly through `release/2`. A ref no longer in `monitors` (the key already
  # moved on through a normal release/re-acquire, which always demonitors first)
  # resolves to nothing here.
  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, key} -> {:noreply, forget_key(state, key)}
      :error -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Mint the next revision of a lease for `key` and (re)monitor `holder_pid` —
  # demonitoring any stale prior watch on this key first, so a re-acquire by a
  # NEW process (presenting the same holder string) transfers the watch rather
  # than accumulating monitors, and so `:DOWN` for the OLD holder can never race
  # against the new one's fresh lease.
  defp mint_and_monitor(state, key, holder, expires_at, holder_pid) do
    revision = next_revision(state.leases, key)

    lease = %Lease{
      key: key,
      holder: holder,
      revision: revision,
      expires_at_ms: expires_at
    }

    state = demonitor_key(state, key)
    ref = Process.monitor(holder_pid)

    state = %{
      state
      | leases: Map.put(state.leases, key, lease),
        monitors: Map.put(state.monitors, ref, key),
        holder_refs: Map.put(state.holder_refs, key, ref)
    }

    {lease, state}
  end

  # Free `key` and stop watching it (release, or the holder-process auto-release
  # on :DOWN) — always removes the lease AND both monitor-bookkeeping entries
  # together so they can never drift out of sync.
  defp forget_key(state, key) do
    state = demonitor_key(state, key)
    %{state | leases: Map.delete(state.leases, key)}
  end

  defp demonitor_key(state, key) do
    case Map.fetch(state.holder_refs, key) do
      {:ok, ref} ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | monitors: Map.delete(state.monitors, ref),
            holder_refs: Map.delete(state.holder_refs, key)
        }

      :error ->
        state
    end
  end

  # The lease holding `key` at `now`, or `nil` when the key is free (unheld or its
  # lease has expired). Expiry is decided purely against the injected clock.
  @spec live_lease(map(), Lease.key(), non_neg_integer()) :: Lease.t() | nil
  defp live_lease(leases, key, now) do
    case Map.get(leases, key) do
      %Lease{} = lease -> if Lease.expired?(lease, now), do: nil, else: lease
      nil -> nil
    end
  end

  # Monotonic per-key revision: one past the last recorded revision (whether or
  # not it is expired), so a re-acquire after expiry still advances — a stale
  # holder presenting the old revision can never match the live one.
  @spec next_revision(map(), Lease.key()) :: Lease.revision()
  defp next_revision(leases, key) do
    case Map.get(leases, key) do
      %Lease{revision: revision} -> revision + 1
      nil -> 1
    end
  end

  # Resolve the store pid from the `:store` handle. The handle is required: a
  # backend is an instance, never a global, so a missing store is a caller bug.
  @spec store_pid(keyword()) :: pid()
  defp store_pid(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, {__MODULE__, pid}} when is_pid(pid) -> pid
      {:ok, pid} when is_pid(pid) -> pid
      _ -> raise ArgumentError, "#{inspect(__MODULE__)} requires a :store handle in opts"
    end
  end
end

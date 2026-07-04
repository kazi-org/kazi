defmodule Kazi.Coordination.Lease.Memory do
  @moduledoc """
  The in-process `Kazi.Coordination.Lease` backend: the **real single-node
  default**, and the test double for the shared conformance suite (T3.1a,
  ADR-0006; UC-013).

  This is not a stub. Within one BEAM node it is a correct, concurrency-safe lease
  store: an `Agent` holds the `key => %Lease{}` map, and every mutation
  (acquire/renew/release) runs inside `Agent.get_and_update/2`, so the
  compare-and-set is **atomic** — two processes racing to acquire the same free
  key serialize through the Agent and exactly one wins. The NATS JetStream KV
  backend (T3.1b) replaces this only when work must coordinate *across* nodes; on
  a single node this backend is the production path, not a placeholder.

  ## Instance, not global

  A backend is a running `Agent` referenced by a `{__MODULE__, pid}` tuple, passed
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
  """

  @behaviour Kazi.Coordination.Lease

  use Agent

  alias Kazi.Coordination.Lease

  @typedoc "An opaque handle to a running store: the module-tagged Agent pid."
  @type store :: {__MODULE__, pid()}

  @doc """
  Starts a fresh, empty lease store and returns `{:ok, store_handle}`.

  The handle is the `{__MODULE__, pid}` tuple passed back per call as `:store`.
  Accepts standard `Agent.start_link/2` options (e.g. `:name`) under `opts`.
  """
  @spec start_link(keyword()) :: {:ok, store()} | {:error, term()}
  def start_link(opts \\ []) do
    case Agent.start_link(fn -> %{} end, opts) do
      {:ok, pid} -> {:ok, {__MODULE__, pid}}
      {:error, _reason} = error -> error
    end
  end

  @impl Lease
  def acquire(key, holder, ttl_ms, opts)
      when is_binary(key) and is_binary(holder) and is_integer(ttl_ms) and ttl_ms > 0 do
    pid = store_pid(opts)
    now = Lease.now_ms(opts)
    expires_at = now + ttl_ms

    # The whole acquire — free/held check, mint, store — runs inside one
    # get_and_update so two racing acquirers on the same key cannot both win.
    Agent.get_and_update(pid, fn leases ->
      case live_lease(leases, key, now) do
        # Free at `now` (unheld or expired) — or held by us: mint/refresh.
        nil ->
          mint(leases, key, holder, expires_at)

        %Lease{holder: ^holder} ->
          mint(leases, key, holder, expires_at)

        # A different, unexpired holder owns it.
        %Lease{} ->
          {{:error, :held}, leases}
      end
    end)
  end

  @impl Lease
  def renew(%Lease{key: key, holder: holder, revision: revision}, ttl_ms, opts)
      when is_integer(ttl_ms) and ttl_ms > 0 do
    pid = store_pid(opts)
    now = Lease.now_ms(opts)
    expires_at = now + ttl_ms

    Agent.get_and_update(pid, fn leases ->
      case live_lease(leases, key, now) do
        # Still the current, unexpired lease we hold — extend + bump revision.
        %Lease{holder: ^holder, revision: ^revision} ->
          mint(leases, key, holder, expires_at)

        # Superseded (revision moved on / re-acquired / expired / released).
        _other ->
          {{:error, :not_held}, leases}
      end
    end)
  end

  @impl Lease
  def release(%Lease{key: key, holder: holder, revision: revision}, opts) do
    pid = store_pid(opts)
    now = Lease.now_ms(opts)

    Agent.get_and_update(pid, fn leases ->
      case live_lease(leases, key, now) do
        # We are the current holder — free the key.
        %Lease{holder: ^holder, revision: ^revision} ->
          {:ok, Map.delete(leases, key)}

        # Already free, expired, or superseded — releasing is a no-op.
        _other ->
          {:ok, leases}
      end
    end)
  end

  @impl Lease
  def peek(key, opts) when is_binary(key) do
    pid = store_pid(opts)
    now = Lease.now_ms(opts)

    Agent.get(pid, fn leases ->
      case live_lease(leases, key, now) do
        %Lease{} = lease -> {:ok, lease}
        nil -> :free
      end
    end)
  end

  # Mint the next revision of a lease (acquire or renew share this), returning the
  # new lease both as the call result and stored under `key`.
  @spec mint(map(), Lease.key(), Lease.holder(), non_neg_integer()) ::
          {{:ok, Lease.t()}, map()}
  defp mint(leases, key, holder, expires_at) do
    revision = next_revision(leases, key)

    lease = %Lease{
      key: key,
      holder: holder,
      revision: revision,
      expires_at_ms: expires_at
    }

    {{:ok, lease}, Map.put(leases, key, lease)}
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

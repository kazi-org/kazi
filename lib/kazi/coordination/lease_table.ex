defmodule Kazi.Coordination.LeaseTable do
  @moduledoc """
  A globally-readable registry of the **native (NATS-free) leases** currently held
  in this BEAM (the readable singleton the in-memory lease backend lacked).

  The single-node parallel scheduler coordinates partitions on
  `Kazi.Coordination.Lease.Memory` — a **per-run** `Agent` store passed by handle
  (`:store`), deliberately NOT global (each run is isolated). That makes the leases
  unreadable from outside the run: the operator dashboard (`/leases`,
  `KaziWeb.LeaseMapLive`) could only read leases over the NATS transport, so on a
  native run it had no readable source and 500'd.

  This table is the missing read seam. It is a small, optional, globally-named
  `Agent` of `key => %Kazi.Coordination.Lease{}` that the lease lifecycle records
  into as partitions acquire/release (`Kazi.Scheduler.LeasedReconciler`), so a
  non-NATS coordination source (`KaziWeb.CoordinationSource.Native`) can project
  the live lease map without touching NATS.

  ## Best-effort, never required

  Every write is a NO-OP when the table is not running (the escript / a hermetic
  scheduler test that never starts it), so recording leases here never couples the
  scheduler to the web tree and never crashes a headless run. The full app tree
  (`Kazi.Application`, when the SQLite NIF is present and the dashboard is served)
  starts the singleton; everything else simply skips it. Reads return `[]` when it
  is absent, so the dashboard renders the empty state rather than crashing.

  Like the lease store and the partition supervisor, it is an instance referenced
  by name — the app starts one named `#{inspect(__MODULE__)}`, but a test can start
  its own and pass the name to `record/2`, `forget/2`, and `list/1`.
  """

  use Agent

  alias Kazi.Coordination.Lease

  @doc """
  Starts the lease table (an empty `key => %Lease{}` map).

  Accepts `:name` (defaults to `#{inspect(__MODULE__)}`) so the app starts the
  singleton while a test can start an isolated instance.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc """
  Ensures the named singleton is running, starting it if absent. Idempotent.

  The full app tree (`Kazi.Application`) starts the singleton, but the Burrito
  standalone binary hands straight to the CLI before that tree is stood up (the
  same path that left `Kazi.Repo`/`Kazi.Scheduler.PartitionSupervisor` unstarted),
  so a released `kazi apply --parallel` would have no readable lease table to
  publish into. The CLI parallel path calls this so native partition leases are
  recordable; under mix/test where the app tree already started it, this is a
  no-op returning the running pid.
  """
  @spec ensure_started(atom()) :: {:ok, pid()}
  def ensure_started(name \\ __MODULE__) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case start_link(name: name) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
        end
    end
  end

  @doc """
  Records a held lease, keyed by its `:key`. Best-effort: a no-op when the table is
  not running, so the lease lifecycle never depends on it.
  """
  @spec record(Lease.t(), atom() | pid()) :: :ok
  def record(%Lease{key: key} = lease, name \\ __MODULE__) do
    if alive?(name), do: Agent.update(name, &Map.put(&1, key, lease))
    :ok
  end

  @doc """
  Forgets `lease` (it was released) — but ONLY if the entry currently recorded
  under its `:key` is still held by the SAME `:holder`. `record/2` and
  `forget/2` are two separate `Agent.update` calls, so two partitions
  serializing on the same key can interleave: the outgoing holder's release
  runs its `forget` after the incoming holder has already `record`ed its own
  entry, and an unconditional delete-by-key would erase that fresh entry
  (deep review L8) — the dashboard would then read a held key as free, even
  though the underlying lease backend's CAS keeps coordination itself correct.
  Keying the forget by holder identity makes this a safe no-op instead.

  Best-effort: a no-op when the table is not running.
  """
  @spec forget(Lease.t(), atom() | pid()) :: :ok
  def forget(%Lease{key: key, holder: holder}, name \\ __MODULE__) do
    if alive?(name) do
      Agent.update(name, fn table ->
        case Map.fetch(table, key) do
          {:ok, %Lease{holder: ^holder}} -> Map.delete(table, key)
          _ -> table
        end
      end)
    end

    :ok
  end

  @doc """
  Lists the currently-held leases (`[%Lease{}]`). Returns `[]` when the table is
  not running, so a reader (the dashboard's native source) renders the empty state
  instead of crashing on a NATS-free run.
  """
  @spec list(atom() | pid()) :: [Lease.t()]
  def list(name \\ __MODULE__) do
    if alive?(name), do: Agent.get(name, &Map.values/1), else: []
  end

  defp alive?(name) when is_atom(name), do: is_pid(Process.whereis(name))
  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)
end

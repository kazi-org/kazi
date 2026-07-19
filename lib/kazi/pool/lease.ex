defmodule Kazi.Pool.Lease do
  @moduledoc """
  The per-task BLAST-RADIUS lease a pooled session holds while it edits (T20.6,
  ADR-0026 L3).

  ADR-0026 integrates kazi UNDER each `/apply --pool` session and composes TWO
  coordination layers, not one:

    * `/claim` is the OUTER lock — which session takes which plan TASK (task ids +
      `R-<slug>` shared-file locks). It is acquired FIRST and is coarse: it names a
      task, not the code that task will touch.
    * kazi's blast-radius lease is the INNER lock — what CODE a task's execution may
      touch. Two DIFFERENT tasks (disjoint `/claim` locks) can still edit the SAME
      function and both rebase-merge clean: a SILENT LOGICAL conflict. The
      blast-radius lease closes that gap by serialising on the actual code a task
      touches.

  This module is the thin POOL-SESSION helper for the inner lock: given a task's
  blast-radius inputs (the goals + their evidence terms), it computes the lease
  KEYS via `Kazi.Partition` and acquires a RUN-SCOPED lease over them, with a
  `with`-style lifecycle — acquire -> run -> RELEASE on terminal, including on
  crash/error.

  ## Why a key PER FILE, not one key per partition

  `Kazi.Partition.partition/3` (and `Kazi.Coordination.PartitionLease.lease_keys/3`
  over it) computes overlap across a KNOWN set of goals supplied together, hashing
  each partition's WHOLE radius into one key. That is the scheduler's model
  (T21.3) — it holds all goals at once. A pooled session is different: independent
  sessions arrive SEPARATELY and never see each other's goals, so a per-partition
  hash of two different radii that merely SHARE a file would not collide (the
  hashes differ). To make two independent runs serialise on a shared file, this
  helper leases one key PER blast-radius FILE PATH — `Kazi.Partition.partition_key`
  applied to each single path. Two runs whose radii share ANY path then derive a
  COMMON key and contend; runs with fully disjoint paths derive disjoint key sets
  and run free. The blast radius itself is still computed by `Kazi.Partition`
  (`partition/3` -> the union of each goal's surveyed paths), so there is no new
  graph client.

  ## The compose-boundary in one line

      claim the TASK (/claim)  ->  lease its BLAST RADIUS (this module)  ->  edit

  `with_lease/3` is the inner half: a session that already holds its `/claim`
  task-lock calls it around the edit. Overlapping radii serialise (the second
  caller fails to acquire until the first releases); disjoint radii run free.

  ## Run-scoped, released on terminal (incl. crash)

  The lease is held for the duration of ONE pooled run and freed the moment that
  run reaches a terminal state — convergence, error, or an exception. `with_lease/3`
  wraps the body in `try/after` so the release runs on EVERY exit path: a normal
  return, a raised error, a thrown value, or an `exit`. A pooled session that
  crashes mid-edit therefore does not strand its blast-radius lease and block
  every overlapping run behind it. (Even without that guarantee the lease carries
  a TTL — `Kazi.Coordination.Lease`'s absolute expiry — so a truly lost holder is
  eventually reclaimed; `with_lease/3` makes the common case prompt, not
  TTL-bounded.)

  ## Backend: in-memory default, NATS config-selected

  The lease backend is INJECTED (`:backend`, default
  `Kazi.Coordination.Lease.Memory`). The in-memory backend is the correct
  single-node default — a real, concurrency-safe lease store within one BEAM node,
  not a stub (see `Kazi.Coordination.Lease.Memory`). NATS (ADR-0004) is selected
  only when work must coordinate across machines; this module does NOT require it.
  All backend options (the `:store` handle for the in-memory backend, the injected
  clock `:now_ms`/`:now_fn`) ride in `:lease_opts` and pass straight through, so
  the whole helper is hermetic and testable on a virtual clock.

  ## Serialise vs run-free (the L3 contract)

    * Two runs whose blast radii OVERLAP share at least one path-key — the run that
      reaches the contended key gets `{:error, :held, ...}` and must defer until
      the holder releases on terminal.
    * Two runs whose blast radii are DISJOINT derive DISJOINT key sets — both
      acquire freely and run in parallel.

  See `docs/pool-blast-radius-lease.md` for the copy-pasteable pool-session recipe
  and the `/claim` <-> lease compose-boundary.

  > T20.6 delivers the lease itself. The deeper deadlock-safety contract of the
  > compose-boundary (acquire order, multi-key ordering, TTL/release ordering
  > across the whole pool) is T20.7, a separate task; this module acquires its
  > keys in their already-deterministic order, which is the foundation that
  > contract builds on.
  """

  alias Kazi.Coordination.Lease
  alias Kazi.Partition

  @default_backend Kazi.Coordination.Lease.Memory

  # A blast-radius lease is held for the length of one pooled edit, not forever.
  # The default TTL is a backstop for a crashed holder that somehow skipped the
  # `after` release; the common case releases promptly. Callers pin a value via
  # `:ttl_ms` and can renew if an edit runs long (the session's loop owns renew).
  @default_ttl_ms 300_000

  @typedoc """
  The goals (with their evidence terms) whose blast radius this run leases.
  Accepts the same shapes `Kazi.Partition.partition/3` accepts (a
  `{goal_id, terms}` tuple, a `Kazi.Goal`, or a `%{id:, terms:}` map).
  """
  @type goals :: [Kazi.Partition.goal_input()]

  @typedoc """
  Options for acquiring a blast-radius lease.

    * `:holder` — REQUIRED. The run identity that holds the lease (e.g. the pooled
      run id). Two acquirers with the same holder are the same party (a re-acquire
      refreshes); two DIFFERENT holders on one key contend.
    * `:backend` — the `Kazi.Coordination.Lease` backend module. Defaults to
      `Kazi.Coordination.Lease.Memory` (the single-node default). NATS is selected
      here for multi-machine; not required.
    * `:ttl_ms` — the lease TTL in ms (default 300000). A backstop for a lost
      holder; the lease is normally released on terminal well before this.
    * `:lease_opts` — opts forwarded VERBATIM to the backend's acquire/release
      (e.g. `store:` for the in-memory backend, and the injected clock
      `:now_ms`/`:now_fn`). Hermetic tests pass the test store + a fixed clock here.
    * `:workspace` — the workspace root the blast radius is expanded against
      (default `"."`). Forwarded to `Kazi.Partition.partition/3`.
    * `:graph_source` — forwarded to `Kazi.Partition.partition/3` to expand the
      blast radius (inject a static source for a hermetic, network-free run).
  """
  @type opts :: [
          holder: Lease.holder(),
          backend: module(),
          ttl_ms: Lease.ttl_ms(),
          lease_opts: keyword(),
          workspace: String.t(),
          graph_source: module() | {module(), keyword()}
        ]

  @typedoc """
  A held blast-radius lease: the backend that minted it, the underlying held
  `Kazi.Coordination.Lease` structs (one per lease key in the run's blast radius),
  and the `lease_opts` needed to release them. Opaque — pass it to `release/1`.
  """
  @type held :: %{
          backend: module(),
          leases: [Lease.t()],
          lease_opts: keyword()
        }

  @typedoc """
  Why an acquire failed: `:held` — a different run already holds an OVERLAPPING
  blast-radius key (serialise: retry after it releases on terminal). The held key
  is named so the caller can report which radius it is waiting on.
  """
  @type acquire_error :: {:error, :held, %{key: Lease.key()}}

  @doc """
  Acquires a RUN-SCOPED lease over `goals`' blast radius for `opts[:holder]`.

  Expands the run's blast radius with `Kazi.Partition.partition/3` (the union of
  each goal's surveyed paths) and derives one lease key PER path via
  `Kazi.Partition.partition_key/2`, then acquires EVERY key for the holder — so
  two independent runs that share ANY path contend on that path's key, while runs
  with disjoint paths get disjoint key sets. On success returns `{:ok, held}` —
  pass `held` to `release/1`. On the first key already held by a DIFFERENT run it
  returns `{:error, :held, %{key: key}}` and RELEASES any keys it already took in
  this call, so a partial acquire never strands a lease (all-or-nothing).

  Keys are acquired in sorted (deterministic) order. Re-acquiring a key this same
  holder already owns refreshes it (the backend treats same-holder as a
  no-collision refresh), so a goal-set whose paths overlap internally is safe.

  Prefer `with_lease/3` — it pairs this acquire with a release on EVERY exit path.
  Use `acquire/2` + `release/1` directly only when the lifecycle is not a single
  lexical block.
  """
  @spec acquire(goals(), opts()) :: {:ok, held()} | acquire_error()
  def acquire(goals, opts) when is_list(goals) and is_list(opts) do
    holder = fetch_holder!(opts)
    backend = Keyword.get(opts, :backend, @default_backend)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    lease_opts = Keyword.get(opts, :lease_opts, [])
    workspace = Keyword.get(opts, :workspace, ".")
    partition_opts = Keyword.take(opts, [:graph_source])

    keys = blast_radius_keys(goals, workspace, partition_opts)

    acquire_keys(keys, [], backend, holder, ttl_ms, lease_opts)
  end

  # The run's blast-radius file paths -> one lease key PER path, sorted +
  # de-duplicated for a deterministic acquire order. Two runs sharing any path
  # therefore share that path's key (serialise); disjoint paths -> disjoint keys
  # (parallel). A run with an EMPTY blast radius derives no keys: it touches no
  # shared code, so it never contends — `acquire` succeeds with an empty hold.
  @spec blast_radius_keys(goals(), String.t(), keyword()) :: [Lease.key()]
  defp blast_radius_keys(goals, workspace, partition_opts) do
    goals
    |> Partition.partition(workspace, partition_opts)
    |> Enum.flat_map(& &1.blast_radius)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn path -> Partition.partition_key(["_pool"], [path]) end)
  end

  @doc """
  Releases a held blast-radius lease, freeing every key it holds.

  Total and idempotent: `release/1` calls the backend's `release/2` (itself
  idempotent — a stale or already-free key is a no-op `:ok`) for each held lease,
  so releasing twice, or releasing after a key's TTL already expired, is safe.
  Always returns `:ok`. This is what `with_lease/3` calls in its `after`.
  """
  @spec release(held()) :: :ok
  def release(%{backend: backend, leases: leases, lease_opts: lease_opts}) do
    Enum.each(leases, fn %Lease{} = lease -> backend.release(lease, lease_opts) end)
    :ok
  end

  @doc """
  Runs `fun` while holding `goals`' blast-radius lease, releasing on EVERY exit.

  The `with`-style entry point and the one a pooled session should use: it
  `acquire/2`s the run-scoped lease, runs `fun.()`, and releases the lease in an
  `after` so the release happens whether `fun` returns normally, raises, throws,
  or exits — the lease never outlives the run, including on crash. Returns
  `{:ok, fun_result}` on a clean acquire, or `{:error, :held, %{key: key}}` when
  an OVERLAPPING run already holds the radius (the body is NOT run; the caller
  defers and retries after the holder releases).
  """
  @spec with_lease(goals(), opts(), (-> result)) :: {:ok, result} | acquire_error()
        when result: term()
  def with_lease(goals, opts, fun)
      when is_list(goals) and is_list(opts) and is_function(fun, 0) do
    case acquire(goals, opts) do
      {:ok, held} ->
        try do
          {:ok, fun.()}
        after
          release(held)
        end

      {:error, :held, _info} = error ->
        error
    end
  end

  # Acquire each key in order; on the first contended key, roll back the keys
  # already taken in THIS call (all-or-nothing) and report which radius is held.
  defp acquire_keys([], acquired, backend, _holder, _ttl_ms, lease_opts) do
    {:ok, %{backend: backend, leases: Enum.reverse(acquired), lease_opts: lease_opts}}
  end

  defp acquire_keys([key | rest], acquired, backend, holder, ttl_ms, lease_opts) do
    case backend.acquire(key, holder, ttl_ms, lease_opts) do
      {:ok, %Lease{} = lease} ->
        acquire_keys(rest, [lease | acquired], backend, holder, ttl_ms, lease_opts)

      {:error, :held} ->
        # Roll back what we took so a partial acquire never strands a lease.
        release(%{backend: backend, leases: acquired, lease_opts: lease_opts})
        {:error, :held, %{key: key}}
    end
  end

  defp fetch_holder!(opts) do
    case Keyword.fetch(opts, :holder) do
      {:ok, holder} when is_binary(holder) and holder != "" ->
        holder

      _ ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} requires a non-empty :holder (the run identity) in opts"
    end
  end
end

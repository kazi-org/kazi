defmodule Kazi.Pool.Compose do
  @moduledoc """
  The `/claim` <-> kazi-lease COMPOSE-BOUNDARY and its DEADLOCK-SAFETY contract
  (T20.7, ADR-0026 L3).

  ADR-0026 runs kazi UNDER each `/apply --pool` session and composes TWO
  coordination locks, at different granularities:

    * the `/claim` TASK-lock (ADR-0013) -- the OUTER lock, an atomic git-ref at
      `refs/claims/*` that says which session owns which plan TASK; and
    * the kazi BLAST-RADIUS lease (`Kazi.Pool.Lease`, T20.6) -- the INNER lock, a
      CAS/TTL lease over the actual code paths that task touches.

  Two locks held by two sessions is exactly the shape that can DEADLOCK -- session
  A holding lock 1 and waiting on lock 2 while session B holds lock 2 and waits on
  lock 1. This module is the executable statement of the contract that makes that
  impossible. It is not new machinery layered over `Kazi.Pool.Lease`; it is the
  thin lifecycle that PINS the order in code so the order cannot be gotten wrong.

  ## The contract (why two sessions cannot deadlock)

  Deadlock requires all four Coffman conditions at once: mutual exclusion, hold-
  and-wait, no-preemption, and a CIRCULAR WAIT. The boundary breaks two of them,
  so the cycle can never close:

    1. **A consistent GLOBAL lock order breaks circular wait.** Every session
       acquires in the SAME order -- the `/claim` TASK-lock FIRST, then the
       blast-radius LEASE -- and releases in the REVERSE order -- the LEASE first,
       then the claim. With a total order over the two lock CLASSES (claim <
       lease) that every party respects, no cycle in the wait-for graph can form:
       a session can only ever wait "upward" (it holds a claim and waits for a
       lease, never the inverse), and a set of upward-only waits cannot be
       circular. `acquire/1` and `release/1` here enforce that order mechanically.

    2. **The lease TTL breaks no-preemption (liveness backstop).** Even a perfect
       order cannot help if a holder DIES still holding a lock. The blast-radius
       lease carries an ABSOLUTE `expires_at_ms` (`Kazi.Coordination.Lease`): a
       crashed session's lease becomes free at `now_ms >= expires_at_ms` and is
       reclaimed by the next acquirer with NO action from the dead holder. TTL is
       the preemption a pure-ordering argument lacks, so a dead holder bounds the
       wait instead of blocking it forever. (The `/claim` git-ref lock has its own
       liveness story -- `/claim prune` -- outside this module; the lease is the
       part kazi owns and the part these tests exercise on an injected clock.)

  Mutual exclusion and hold-and-wait remain (they are the point -- the locks must
  exclude), but with circular-wait and no-preemption both broken, the four
  conditions never co-occur and the boundary is deadlock-free.

  ## Acquire order, run, release order -- in one line

      claim TASK (outer, first)  ->  lease BLAST RADIUS (inner)  ->  edit
        ->  release LEASE (inner, first)  ->  release CLAIM (outer, last)

  `with_boundary/2` runs that whole lifecycle and releases in the correct REVERSE
  order on EVERY exit path (normal return, raise, throw, exit), so a crash mid-
  edit never leaves the lease held ahead of the claim, and never strands either.

  ## Modeling `/claim` for a hermetic test

  The real `/claim` lock is an atomic git-ref push, not an Elixir value, so kazi
  cannot acquire it in-process. But the DEADLOCK-SAFETY property is about lock
  ORDER and TTL liveness, not about git -- it holds for ANY two mutually-exclusive
  locks acquired in a consistent order. So this module takes the claim as an
  INJECTED lock interface (`acquire_claim` / `release_claim` funs), letting a test
  model the `/claim` task-lock as a second `Kazi.Coordination.Lease` key over the
  same in-memory backend and assert the no-deadlock property end-to-end, with NO
  git and NO NATS. In production a pool session passes funs that shell out to
  `/claim`; the ORDER this module enforces is identical either way.

  See `docs/pool-claim-lease-deadlock-safety.md` for the prose contract and the
  pool-session recipe, and `Kazi.Pool.Lease` for the inner lease itself.
  """

  alias Kazi.Coordination.Lease
  alias Kazi.Pool.Lease, as: PoolLease

  @typedoc """
  The two-tier acquire options.

    * `:task_id` -- REQUIRED. The plan TASK id the `/claim` lock guards (the OUTER
      lock identity, e.g. `"T-1234"`).
    * `:acquire_claim` -- REQUIRED. A one-arity fun `(task_id -> :ok | {:error,
      reason})` that takes the OUTER `/claim` task-lock. Acquired FIRST. In
      production it shells out to `/claim`; in tests it leases a task key on the
      in-memory backend.
    * `:release_claim` -- REQUIRED. A one-arity fun `(task_id -> :ok)` that frees
      the `/claim` task-lock. Released LAST (after the lease).
    * `:lease_goals` -- REQUIRED. The goals whose blast radius the INNER lease
      covers; passed verbatim to `Kazi.Pool.Lease`.
    * `:lease_opts` -- REQUIRED. The opts for `Kazi.Pool.Lease.acquire/2`
      (`:holder`, `:backend`, `:ttl_ms`, `:lease_opts`, `:graph_source`,
      `:workspace`). The lease TTL rides here; it is the crash backstop.
  """
  @type opts :: [
          task_id: String.t(),
          acquire_claim: (String.t() -> :ok | {:error, term()}),
          release_claim: (String.t() -> :ok),
          lease_goals: PoolLease.goals(),
          lease_opts: keyword()
        ]

  @typedoc """
  A held two-tier boundary: the task id (so the claim can be released), the held
  blast-radius lease, and the `release_claim` fun. Opaque -- pass it to
  `release/1`, which frees them in the contract's REVERSE order (lease, then
  claim).
  """
  @type held :: %{
          task_id: String.t(),
          lease: PoolLease.held(),
          release_claim: (String.t() -> :ok)
        }

  @typedoc """
  Why an acquire failed, preserving WHICH layer denied and in a shape that proves
  the order was respected:

    * `{:error, :claim_held, %{task_id:}}` -- the OUTER `/claim` lock was taken by
      another session; the inner lease was NEVER attempted (order: claim first).
    * `{:error, :lease_held, %{key:}}` -- the claim was taken but the INNER lease
      overlaps a live radius; the claim has already been ROLLED BACK so no lock is
      stranded (an acquire that cannot complete holds nothing).
  """
  @type acquire_error ::
          {:error, :claim_held, %{task_id: String.t()}}
          | {:error, :lease_held, %{key: Lease.key()}}

  @doc """
  Acquires the two-tier boundary in the contract order: `/claim` task-lock FIRST,
  then the blast-radius lease.

  On success returns `{:ok, held}` -- pass `held` to `release/1` (which frees in
  reverse order). If the OUTER claim is held, returns `{:error, :claim_held, ...}`
  WITHOUT touching the lease. If the claim is taken but the INNER lease overlaps a
  live radius, the claim is ROLLED BACK (released) before returning `{:error,
  :lease_held, ...}`, so a failed acquire never half-holds: an acquirer either
  holds BOTH locks or NEITHER. That all-or-nothing guarantee is itself part of why
  no deadlock forms -- a session that cannot get its lease does not sit on its
  claim waiting.

  Prefer `with_boundary/2`, which pairs this with `release/1` on every exit path.
  """
  @spec acquire(opts()) :: {:ok, held()} | acquire_error()
  def acquire(opts) when is_list(opts) do
    task_id = fetch!(opts, :task_id)
    acquire_claim = fetch!(opts, :acquire_claim)
    release_claim = fetch!(opts, :release_claim)
    lease_goals = fetch!(opts, :lease_goals)
    lease_opts = fetch!(opts, :lease_opts)

    # ORDER STEP 1 -- the OUTER /claim task-lock, always first.
    case acquire_claim.(task_id) do
      :ok ->
        # ORDER STEP 2 -- the INNER blast-radius lease, always second.
        case PoolLease.acquire(lease_goals, lease_opts) do
          {:ok, lease} ->
            {:ok, %{task_id: task_id, lease: lease, release_claim: release_claim}}

          {:error, :held, %{key: key}} ->
            # The lease overlaps a live radius. Roll the claim back NOW so we never
            # hold the outer lock while blocked on the inner one -- the precise
            # hold-and-wait shape a deadlock needs.
            release_claim.(task_id)
            {:error, :lease_held, %{key: key}}
        end

      {:error, _reason} ->
        # The outer claim is held by another session; never touch the lease.
        {:error, :claim_held, %{task_id: task_id}}
    end
  end

  @doc """
  Releases a held boundary in the contract's REVERSE order: the LEASE first, then
  the `/claim` task-lock.

  Total and idempotent in the lease half (`Kazi.Pool.Lease.release/1` is
  idempotent); the claim release is the injected `release_claim` fun. Always
  returns `:ok`. Releasing the inner lock before the outer one is the mirror of
  acquiring outer-before-inner -- together they form the consistent global order
  that makes a wait-for cycle impossible.
  """
  @spec release(held()) :: :ok
  def release(%{task_id: task_id, lease: lease, release_claim: release_claim}) do
    # REVERSE ORDER -- inner lease first...
    PoolLease.release(lease)
    # ...then the outer claim.
    release_claim.(task_id)
    :ok
  end

  @doc """
  Runs `fun` while holding BOTH locks, releasing them in the contract's reverse
  order on EVERY exit.

  The entry point a pool session should use: it `acquire/1`s the boundary
  (claim-then-lease), runs `fun.()`, and releases (lease-then-claim) in an `after`
  so the release happens whether `fun` returns, raises, throws, or exits. A crash
  mid-edit therefore frees the lease before the claim every time, never inverting
  the order and never stranding a lock. Returns `{:ok, fun_result}` on a clean
  acquire, or the `acquire_error` (the body is NOT run) when either lock is held.

  `fun` is invoked as `fun.(held)` so the body can observe/renew the held lease if
  an edit runs long.
  """
  @spec with_boundary(opts(), (held() -> result)) :: {:ok, result} | acquire_error()
        when result: term()
  def with_boundary(opts, fun) when is_list(opts) and is_function(fun, 1) do
    case acquire(opts) do
      {:ok, held} ->
        try do
          {:ok, fun.(held)}
        after
          release(held)
        end

      {:error, _which, _info} = error ->
        error
    end
  end

  defp fetch!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} requires #{inspect(key)} in opts (the compose-boundary contract)"
    end
  end
end

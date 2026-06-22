defmodule Kazi.Coordination.Lease do
  @moduledoc """
  A per-key resource lease — and the **behaviour** every concrete lease backend
  implements (T3.1a, ADR-0004, ADR-0006; UC-013).

  kazi coordinates parallel work on **resources, not identities** (ADR-0006):
  before an agent edits a blast radius it leases that resource key, so disjoint
  lease-sets run concurrently while overlapping ones serialize. This module is
  the *substrate* under that decision — the narrow CAS/TTL contract a lease store
  must satisfy — kept independent of how it is stored.

  This module is deliberately *both*:

    * a **data type** (`%Kazi.Coordination.Lease{}`) — a held lease: the `key`, the
      `holder` that holds it, the compare-and-set `revision` that proves *which*
      acquisition this is, and the absolute `expires_at_ms` after which it is free;
    * a **behaviour** (`@callback acquire/4` and friends) — the contract a backend
      implements to actually store and arbitrate leases.

  ## Why CAS + an absolute expiry

  Mutual exclusion is enforced by **compare-and-set on a monotonic revision**, not
  by holding a process or a lock object: `acquire/4` succeeds only when the key is
  free (or already held by the same holder), minting a new `revision`; `renew/3`
  and `release/2` only act when they present the *current* revision, so a stale
  holder whose lease already expired and was re-acquired by someone else cannot
  renew or release out from under the new owner. This is the same revision-CAS
  shape JetStream KV gives the real backend (T3.1b), so the in-memory default and
  the NATS backend share one contract.

  TTL is an **absolute** `expires_at_ms` rather than a duration so expiry is a pure
  comparison against a clock the caller supplies (`:now_ms` / `:now_fn` in `opts`).
  A backend MUST treat time as injected — never read a wall clock directly in a
  path a test cannot control — so TTL expiry is deterministic in the
  conformance suite (`Kazi.Coordination.LeaseContract`). The in-memory default
  (`Kazi.Coordination.Lease.Memory`) and any backend are exercised by that one
  shared suite.

  ## The contract in one paragraph

  `acquire(key, holder, ttl_ms, opts)` returns `{:ok, lease}` when the key is free
  *at `now_ms`* (an expired holder counts as free) or is already held by `holder`
  (a re-acquire that refreshes the TTL and bumps the revision); it returns
  `{:error, :held}` when a *different, unexpired* holder owns the key. `renew/3`
  extends a lease's `expires_at_ms` by `ttl_ms` from `now_ms`, returning
  `{:ok, renewed}` with a bumped revision, or `{:error, :not_held}` if the
  presented lease is no longer current (revision mismatch, expired, or released).
  `release/2` frees the key iff the presented lease is current, returning `:ok`
  (idempotent — releasing an already-free/superseded key is still `:ok`).
  `peek/2` reports the live owner of a key at `now_ms` for observability.
  """

  @typedoc "The resource key a lease guards (e.g. a blast-radius identifier)."
  @type key :: String.t()

  @typedoc """
  The identity holding a lease — an opaque token naming *who* holds it (e.g. a
  kazi instance id). Two acquirers with the same `holder` are treated as the same
  party: a re-acquire refreshes rather than collides.
  """
  @type holder :: String.t()

  @typedoc "A time-to-live in milliseconds; the lease expires this long after `now_ms`."
  @type ttl_ms :: pos_integer()

  @typedoc """
  The monotonic compare-and-set revision of a held lease. Bumped on every
  successful acquire/renew; a backend uses it to reject a stale holder's
  renew/release after the key has moved on.
  """
  @type revision :: pos_integer()

  @typedoc """
  Per-call options. Time is **always** injected so expiry is deterministic:

    * `:now_ms` — the current time in ms, taken as the moment of the call;
    * `:now_fn` — a zero-arity fn returning the current time in ms (used when
      `:now_ms` is absent), so a test can drive a virtual clock.

  A backend MUST resolve the clock from these (see `now_ms/1`) and never read a
  wall clock directly. Backend-specific options (a store pid, a bucket name) may
  also ride here.
  """
  @type opts :: keyword()

  @typedoc """
  A held lease.

    * `:key` — the resource key it guards;
    * `:holder` — who holds it;
    * `:revision` — the CAS revision proving which acquisition this is;
    * `:expires_at_ms` — the absolute ms after which the lease is free.
  """
  @type t :: %__MODULE__{
          key: key(),
          holder: holder(),
          revision: revision(),
          expires_at_ms: non_neg_integer()
        }

  @enforce_keys [:key, :holder, :revision, :expires_at_ms]
  defstruct [:key, :holder, :revision, :expires_at_ms]

  @doc """
  Acquires the lease on `key` for `holder`, valid for `ttl_ms` from `now_ms`.

  Succeeds (`{:ok, lease}`) when the key is **free at `now_ms`** — never acquired,
  or held by a lease whose `expires_at_ms` has passed — or already held by the
  *same* `holder` (a re-acquire that refreshes the TTL and bumps the revision).
  Returns `{:error, :held}` when a *different* holder owns the key with an
  unexpired lease: acquisition is mutually exclusive per key.
  """
  @callback acquire(key(), holder(), ttl_ms(), opts()) :: {:ok, t()} | {:error, :held}

  @doc """
  Renews `lease`, extending its expiry to `now_ms + ttl_ms` and bumping the
  revision.

  Returns `{:ok, renewed}` only when `lease` is still **current** — the same
  holder/revision the backend records, and not yet expired. Returns
  `{:error, :not_held}` when the presented lease has been superseded (revision
  moved on, key re-acquired by another holder, expired, or released): a stale
  holder cannot extend a lease the key has moved past.
  """
  @callback renew(t(), ttl_ms(), opts()) :: {:ok, t()} | {:error, :not_held}

  @doc """
  Releases `lease`, freeing `key` iff the presented lease is current.

  Idempotent and total: returns `:ok` whether it freed a held key or the key was
  already free / held by a newer revision (a stale release is a no-op, not an
  error) — so a crash-and-retry release path is safe.
  """
  @callback release(t(), opts()) :: :ok

  @doc """
  Reports the live owner of `key` at `now_ms`, for observability.

  Returns `{:ok, lease}` when an unexpired lease holds the key, or `:free` when
  the key is unheld or its lease has expired. Does not mutate state.
  """
  @callback peek(key(), opts()) :: {:ok, t()} | :free

  @doc """
  Resolves the current time in ms from `opts`, the one place a backend reads
  "now".

  Precedence: an explicit `:now_ms` wins; else `:now_fn.()` is called; else a
  monotonic system clock is read. Backends MUST funnel every time read through
  this (or an equivalent that honours `:now_ms`/`:now_fn`) so the conformance
  suite can pin TTL expiry to a virtual clock — never call `System.*_time/1`
  directly in an expiry path.

  ## Examples

      iex> Kazi.Coordination.Lease.now_ms(now_ms: 1_000)
      1_000

      iex> Kazi.Coordination.Lease.now_ms(now_fn: fn -> 42 end)
      42
  """
  @spec now_ms(opts()) :: non_neg_integer()
  def now_ms(opts) when is_list(opts) do
    cond do
      is_integer(ms = Keyword.get(opts, :now_ms)) -> ms
      is_function(fun = Keyword.get(opts, :now_fn), 0) -> fun.()
      true -> System.monotonic_time(:millisecond)
    end
  end

  @doc """
  Whether `lease` is expired at `now_ms` (its `expires_at_ms` has passed).

  Expiry is a hard boundary at the TTL: a lease minted with `ttl_ms` at `t` is
  live for `t..t+ttl_ms-1` and free at `t+ttl_ms`. Pure, so a backend's free/held
  decision is a deterministic comparison against the injected clock.

  ## Examples

      iex> lease = %Kazi.Coordination.Lease{key: "k", holder: "h", revision: 1, expires_at_ms: 100}
      iex> Kazi.Coordination.Lease.expired?(lease, 99)
      false

      iex> lease = %Kazi.Coordination.Lease{key: "k", holder: "h", revision: 1, expires_at_ms: 100}
      iex> Kazi.Coordination.Lease.expired?(lease, 100)
      true
  """
  @spec expired?(t(), non_neg_integer()) :: boolean()
  def expired?(%__MODULE__{expires_at_ms: expires_at_ms}, now_ms)
      when is_integer(now_ms) do
    now_ms >= expires_at_ms
  end
end

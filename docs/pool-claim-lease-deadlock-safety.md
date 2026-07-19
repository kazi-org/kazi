# The /claim <-> kazi-lease compose-boundary + deadlock safety (T20.7, ADR-0026 L3)

This note is the DEADLOCK-SAFETY CONTRACT for the two-tier coordination ADR-0026
composes under each `/apply --pool` session. T20.6 (`docs/pool-blast-radius-lease.md`)
delivered the inner lease; this note specifies WHY two sessions, each holding a
`/claim` task-lock AND a kazi blast-radius lease, CANNOT deadlock -- and pins the
acquire/release order in code so the contract cannot be violated by accident.

The executable form is `Kazi.Pool.Compose` (`lib/kazi/pool/compose.ex`); the
acceptance suite is `test/kazi/pool/compose_test.exs` (hermetic -- in-memory
backend, injected clock, NO git, NO NATS).

## The two locks

A pooled session holds TWO mutually-exclusive locks at different granularities:

- the `/claim` TASK-lock (ADR-0013) -- the OUTER lock, an atomic git-ref at
  `refs/claims/*` naming which session owns which plan TASK (a `T-`/`S-` id);
- the kazi BLAST-RADIUS lease (`Kazi.Pool.Lease`, T20.6) -- the INNER lock, a
  CAS/TTL lease over the actual code paths that task touches.

Two locks held by two sessions is the textbook deadlock shape: A holds lock 1 and
waits on lock 2 while B holds lock 2 and waits on lock 1. The contract below makes
that cycle impossible to form.

## The contract

```
ACQUIRE:  /claim TASK (outer, FIRST)  ->  lease BLAST RADIUS (inner, SECOND)  ->  edit
RELEASE:  release LEASE (inner, FIRST)  ->  release CLAIM (outer, LAST)
```

1. **ACQUIRE ORDER -- claim first, then lease.** Every session acquires in the
   SAME order: the `/claim` task-lock first, then the blast-radius lease. The
   claim is the coarse outer selection; the lease is the fine inner radius.

2. **TTL -- the lease bounds a crashed holder.** The blast-radius lease carries an
   ABSOLUTE `expires_at_ms` (`Kazi.Coordination.Lease`). A crashed session's lease
   becomes free at `now_ms >= expires_at_ms` and is reclaimed by the next acquirer
   with NO action from the dead holder. (The `/claim` git-ref lock has its own
   liveness path, `/claim prune`, outside kazi; the lease TTL is the part kazi
   owns and the part the suite exercises on an injected clock.)

3. **RELEASE ORDER -- lease before claim (reverse of acquire).** On terminal
   (convergence, error, crash) the inner lease is released FIRST, then the outer
   claim. `Kazi.Pool.Compose.with_boundary/2` releases in this order on EVERY exit
   path -- normal return, raise, throw, exit -- so a crash mid-edit never frees the
   claim ahead of the lease and never strands either lock.

## Why this prevents deadlock

Deadlock needs all four Coffman conditions AT ONCE: mutual exclusion, hold-and-
wait, no-preemption, and a CIRCULAR WAIT. The boundary breaks two of them, so the
four never co-occur:

- **A consistent global lock order breaks CIRCULAR WAIT.** Impose a total order
  over the two lock CLASSES: `claim < lease`. Every session acquires low-to-high
  (claim then lease) and releases high-to-low (lease then claim). A session can
  therefore only ever wait "upward" in that order -- it may hold a claim and wait
  for a lease, but it can NEVER hold a lease and wait for a claim. A wait-for
  graph whose edges all point one way up a total order has no cycle, so no
  circular wait can form. This is the standard lock-ordering result; the boundary
  just makes the order mechanical instead of conventional.

  Concretely, `Kazi.Pool.Compose.acquire/1` takes the claim first; if the inner
  lease is then contended it ROLLS THE CLAIM BACK before returning, so a session
  that cannot get its lease does not sit on its claim waiting -- it holds NEITHER
  lock and retries. Two different tasks whose radii overlap thus SERIALIZE on the
  lease (one proceeds, the other waits, then proceeds after release) instead of
  deadlocking.

- **The lease TTL breaks NO-PREEMPTION (liveness backstop).** Ordering alone is
  not enough if a holder DIES holding a lock -- the wait would be unbounded. The
  lease's absolute TTL is the preemption a pure-ordering argument lacks: a dead
  holder's lease is reclaimed by the clock, so the wait is bounded, not blocked
  forever. With both circular-wait and no-preemption broken, the boundary is
  deadlock-free even under crashes.

Mutual exclusion and hold-and-wait remain -- that is the point, the locks must
exclude -- but two of the four conditions are structurally absent, so a deadlock
cannot occur.

## Recipe -- a pool session

A session already owns its `/claim` task-lock conceptually; `Kazi.Pool.Compose`
acquires it (via injected funs) FIRST, then the blast-radius lease, and releases
in reverse on every exit:

```elixir
# The /claim task-lock is a git-ref push, not an Elixir value, so it is injected
# as funs. In production these shell out to /claim; the ORDER the boundary
# enforces is identical to the in-memory test model.
opts = [
  task_id: "T-1234",
  acquire_claim: fn task_id -> Claim.acquire(task_id) end,   # OUTER, taken FIRST
  release_claim: fn task_id -> Claim.release(task_id) end,   # OUTER, freed LAST
  lease_goals: [{"T-1234", ["lib/kazi/loop.ex", "Kazi.Loop.observe"]}],
  lease_opts: [holder: run_id, workspace: File.cwd!(), lease_opts: lease_opts]
]

case Kazi.Pool.Compose.with_boundary(opts, fn _held ->
       do_the_edit_and_kazi_run()      # both locks held; released in reverse after
     end) do
  {:ok, result} ->
    result                              # both locks already released (lease, then claim)

  {:error, :claim_held, %{task_id: id}} ->
    {:wait, {:claim, id}}               # another session owns the task; retry

  {:error, :lease_held, %{key: key}} ->
    {:wait, {:lease, key}}              # overlapping radius; the claim was rolled
                                        # back, so we hold nothing -- retry
end
```

## Hermetic test shape

The deadlock property is about lock ORDER and TTL liveness, not about git, so the
suite models the `/claim` task-lock as a SECOND `Kazi.Coordination.Lease` key over
the same in-memory backend and drives the blast-radius lease's TTL on an injected
clock (`now_fn:` reading a mutable counter the test advances). It asserts:

- ACQUIRE ORDER -- a held outer claim denies before the inner lease is touched;
- NO DEADLOCK -- a constructed cross-acquire over overlapping radii SERIALIZES
  (one proceeds, the other waits, then proceeds after release);
- TTL LIVENESS -- a crashed holder's lease is reclaimed once the clock crosses its
  absolute expiry;
- RELEASE ORDER -- the lease is freed BEFORE the claim, on clean return and on a
  raised crash.

No NATS, no git, no wall clock. See `test/kazi/pool/compose_test.exs`.

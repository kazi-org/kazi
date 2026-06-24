defmodule Kazi.Pool.ComposeTest do
  @moduledoc """
  T20.7 acceptance (ADR-0026 L3): the `/claim` <-> kazi-lease COMPOSE-BOUNDARY and
  its DEADLOCK-SAFETY contract.

  Every case is hermetic -- NO git, NO NATS. The `/claim` task-lock is MODELED as
  a second `Kazi.Coordination.Lease` key over the same in-memory backend (the
  deadlock property is about lock ORDER + TTL, not about git), and the blast-radius
  lease's TTL is exercised on a fixed, INJECTED clock so a crashed holder's
  reclamation is deterministic.

  The acceptance bar:

    * ACQUIRE ORDER -- claim FIRST, then lease: a held outer claim denies before
      the inner lease is ever touched.
    * NO DEADLOCK -- two sessions over OVERLAPPING radii, each acquiring in the
      prescribed order, SERIALIZE: one proceeds, the other waits, then proceeds
      after release/TTL. A constructed cross-acquire scenario does NOT deadlock.
    * TTL LIVENESS -- a crashed holder's lease is reclaimed via TTL (injected
      clock advanced past `expires_at_ms`).
    * RELEASE ORDER -- the LEASE is released BEFORE the `/claim` task-lock (reverse
      of acquire); asserted via an order-recording release fun.
  """
  use ExUnit.Case, async: true

  alias Kazi.Context.{FileRef, Survey}
  alias Kazi.Coordination.Lease
  alias Kazi.Pool.Compose

  # A graph-source double whose survey depends on the goal's evidence terms, so two
  # runs can have overlapping or disjoint blast radii. `mapping` is
  # `term -> [file paths]`; the survey is the union over the goal's terms. (Mirrors
  # LeaseTest.TermSource so both suites model radii the same way.)
  defmodule TermSource do
    @moduledoc false
    @behaviour Kazi.Context.GraphSource

    @impl true
    def survey(_workspace, terms, opts) do
      mapping = Keyword.fetch!(opts, :mapping)

      files =
        terms
        |> Enum.flat_map(fn term -> Map.get(mapping, term, []) end)
        |> Enum.uniq()
        |> Enum.map(&FileRef.new/1)

      Survey.new(:graph, files: files)
    end

    def new(mapping), do: {__MODULE__, mapping: mapping}
  end

  # Models the OUTER `/claim` task-lock as a Kazi.Coordination.Lease key. The
  # deadlock property is order + TTL, not git, so a second lease key over the same
  # in-memory backend is a faithful stand-in. Returns claim funs the boundary can
  # acquire FIRST and release LAST. `clock` is shared with the blast-radius lease
  # so the whole boundary runs on ONE injected clock.
  defp claim_funs(store, holder, clock_opts) do
    claim_opts = [store: store] ++ clock_opts
    # A long TTL on the claim: these tests free the claim only by explicit release,
    # never by claim-TTL expiry (the blast-radius lease is the TTL path under test).
    claim_ttl = 3_600_000

    acquire = fn task_id ->
      case Lease.Memory.acquire("claim:" <> task_id, holder, claim_ttl, claim_opts) do
        {:ok, %Lease{} = held} ->
          # Stash the held lease so release can present the current revision.
          Process.put({:claim, task_id, holder}, held)
          :ok

        {:error, :held} ->
          {:error, :claim_held}
      end
    end

    release = fn task_id ->
      case Process.get({:claim, task_id, holder}) do
        %Lease{} = held -> Lease.Memory.release(held, claim_opts)
        nil -> :ok
      end

      :ok
    end

    {acquire, release}
  end

  setup do
    {:ok, store} = Lease.Memory.start_link()
    # A mutable injected clock: a counter the tests advance to drive TTL expiry
    # deterministically. now_fn reads it; tests bump it to cross a lease's expiry.
    clock = :counters.new(1, [])
    clock_opts = [now_fn: fn -> :counters.get(clock, 1) end]
    lease_opts = [store: store] ++ clock_opts

    {:ok, store: store, clock: clock, clock_opts: clock_opts, lease_opts: lease_opts}
  end

  defp set_clock(clock, ms), do: :counters.put(clock, 1, ms)

  describe "acquire order -- claim FIRST, then the blast-radius lease" do
    test "a held outer claim denies before the inner lease is touched",
         %{store: store, clock_opts: clock_opts, lease_opts: lease_opts} do
      source = TermSource.new(%{"t" => ["lib/a.ex"]})
      {acq_a, rel_a} = claim_funs(store, "session-a", clock_opts)
      {acq_b, rel_b} = claim_funs(store, "session-b", clock_opts)

      # session-a takes the claim for T-1 (and its lease).
      assert {:ok, _held_a} =
               Compose.acquire(
                 task_id: "T-1",
                 acquire_claim: acq_a,
                 release_claim: rel_a,
                 lease_goals: [{"g1", ["t"]}],
                 lease_opts: [holder: "session-a", graph_source: source, lease_opts: lease_opts]
               )

      # session-b wants the SAME task: the OUTER claim denies. The error names the
      # claim layer -- the lease was never attempted (order: claim first).
      assert {:error, :claim_held, %{task_id: "T-1"}} =
               Compose.acquire(
                 task_id: "T-1",
                 acquire_claim: acq_b,
                 release_claim: rel_b,
                 lease_goals: [{"g9", ["t"]}],
                 lease_opts: [holder: "session-b", graph_source: source, lease_opts: lease_opts]
               )
    end

    test "claim taken but lease overlaps -> claim is ROLLED BACK (holds NEITHER lock)",
         %{store: store, clock_opts: clock_opts, lease_opts: lease_opts} do
      # Two DIFFERENT tasks (disjoint claims) whose blast radii OVERLAP on a file:
      # the silent-logical-conflict shape the inner lease exists to catch.
      source = TermSource.new(%{"r" => ["lib/shared.ex"]})
      {acq_a, rel_a} = claim_funs(store, "session-a", clock_opts)
      {acq_b, rel_b} = claim_funs(store, "session-b", clock_opts)

      # session-a holds T-1's claim + the shared radius.
      assert {:ok, _held_a} =
               Compose.acquire(
                 task_id: "T-1",
                 acquire_claim: acq_a,
                 release_claim: rel_a,
                 lease_goals: [{"g1", ["r"]}],
                 lease_opts: [holder: "session-a", graph_source: source, lease_opts: lease_opts]
               )

      # session-b's DIFFERENT task T-2 gets its claim, but the overlapping lease is
      # denied -> the boundary rolls the claim back and reports :lease_held.
      assert {:error, :lease_held, %{key: _}} =
               Compose.acquire(
                 task_id: "T-2",
                 acquire_claim: acq_b,
                 release_claim: rel_b,
                 lease_goals: [{"g2", ["r"]}],
                 lease_opts: [holder: "session-b", graph_source: source, lease_opts: lease_opts]
               )

      # PROOF the claim was rolled back: session-b can re-take T-2's claim cleanly
      # (it does not still hold it). Use a disjoint radius so only the claim is in
      # question here.
      disjoint = TermSource.new(%{"r" => ["lib/b.ex"]})

      assert {:ok, _held_b} =
               Compose.acquire(
                 task_id: "T-2",
                 acquire_claim: acq_b,
                 release_claim: rel_b,
                 lease_goals: [{"g2", ["r"]}],
                 lease_opts: [holder: "session-b", graph_source: disjoint, lease_opts: lease_opts]
               )
    end
  end

  describe "no deadlock -- two sessions over overlapping radii SERIALIZE" do
    test "constructed cross-acquire: one proceeds, the other waits then proceeds",
         %{store: store, clock_opts: clock_opts, lease_opts: lease_opts} do
      # The classic deadlock setup, defused by the global lock order: two DIFFERENT
      # tasks (T-1, T-2) whose blast radii OVERLAP on lib/shared.ex. If the two
      # locks were acquirable in either order, A could hold claim/lease for one and
      # block on the other while B did the inverse -> a cycle. The contract forbids
      # that: both acquire claim-then-lease, so the wait graph is acyclic.
      source =
        TermSource.new(%{
          "r1" => ["lib/shared.ex", "lib/a.ex"],
          "r2" => ["lib/shared.ex", "lib/b.ex"]
        })

      {acq_a, rel_a} = claim_funs(store, "session-a", clock_opts)
      {acq_b, rel_b} = claim_funs(store, "session-b", clock_opts)

      a_opts = [
        task_id: "T-1",
        acquire_claim: acq_a,
        release_claim: rel_a,
        lease_goals: [{"g1", ["r1"]}],
        lease_opts: [holder: "session-a", graph_source: source, lease_opts: lease_opts]
      ]

      b_opts = [
        task_id: "T-2",
        acquire_claim: acq_b,
        release_claim: rel_b,
        lease_goals: [{"g2", ["r2"]}],
        lease_opts: [holder: "session-b", graph_source: source, lease_opts: lease_opts]
      ]

      # session-a proceeds (holds both its claim and the shared radius).
      assert {:ok, held_a} = Compose.acquire(a_opts)

      # session-b's claim is disjoint (T-2 != T-1), so it takes its claim -- but the
      # OVERLAPPING lease serializes it. It WAITS (no deadlock, no block on A's
      # claim) and the boundary rolls B's claim back so B holds nothing.
      assert {:error, :lease_held, %{key: contended}} = Compose.acquire(b_opts)
      assert is_binary(contended)

      # session-a reaches terminal and releases (lease then claim).
      assert :ok = Compose.release(held_a)

      # Now session-b proceeds: the overlapping radius is free. The waiter advanced
      # AFTER the holder released -- serialized, never deadlocked.
      assert {:ok, _held_b} = Compose.acquire(b_opts)
    end
  end

  describe "TTL liveness -- a crashed holder's lease is reclaimed" do
    test "an expired lease is reclaimed via TTL on an injected clock",
         %{store: store, clock: clock, clock_opts: clock_opts, lease_opts: lease_opts} do
      source = TermSource.new(%{"r" => ["lib/shared.ex"]})
      {acq_a, rel_a} = claim_funs(store, "session-a", clock_opts)
      {acq_b, rel_b} = claim_funs(store, "session-b", clock_opts)

      ttl = 30_000
      set_clock(clock, 0)

      # session-a acquires both locks at t=0 with a 30s lease TTL, then CRASHES
      # without releasing -- we simply never call Compose.release/1 on its hold.
      assert {:ok, _stranded} =
               Compose.acquire(
                 task_id: "T-1",
                 acquire_claim: acq_a,
                 release_claim: rel_a,
                 lease_goals: [{"g1", ["r"]}],
                 lease_opts: [
                   holder: "session-a",
                   ttl_ms: ttl,
                   graph_source: source,
                   lease_opts: lease_opts
                 ]
               )

      # Before TTL: session-b's DIFFERENT task on the overlapping radius is denied
      # (the stranded lease is still live at t < 30000).
      set_clock(clock, ttl - 1)

      assert {:error, :lease_held, %{key: _}} =
               Compose.acquire(
                 task_id: "T-2",
                 acquire_claim: acq_b,
                 release_claim: rel_b,
                 lease_goals: [{"g2", ["r"]}],
                 lease_opts: [holder: "session-b", graph_source: source, lease_opts: lease_opts]
               )

      # Advance the clock PAST the lease's absolute expiry: the dead holder's lease
      # is now free with no action from the crashed session. session-b reclaims it.
      set_clock(clock, ttl)

      assert {:ok, _held_b} =
               Compose.acquire(
                 task_id: "T-2",
                 acquire_claim: acq_b,
                 release_claim: rel_b,
                 lease_goals: [{"g2", ["r"]}],
                 lease_opts: [holder: "session-b", graph_source: source, lease_opts: lease_opts]
               )
    end
  end

  describe "release order -- the LEASE is freed BEFORE the /claim task-lock" do
    test "release/1 frees inner lease, then outer claim (reverse of acquire)",
         %{store: store, clock_opts: clock_opts, lease_opts: lease_opts} do
      source = TermSource.new(%{"t" => ["lib/a.ex"]})

      # A release fun that records WHEN the claim is freed, relative to the lease.
      order = :counters.new(1, [])
      log = self()

      {acq, _rel} = claim_funs(store, "session-a", clock_opts)

      recording_release = fn task_id ->
        # Record the claim-release tick, then actually free the claim.
        step = :counters.get(order, 1)
        send(log, {:claim_released_at_step, step})

        case Process.get({:claim, task_id, "session-a"}) do
          %Lease{} = held -> Lease.Memory.release(held, [store: store] ++ clock_opts)
          nil -> :ok
        end

        :ok
      end

      {:ok, held} =
        Compose.acquire(
          task_id: "T-1",
          acquire_claim: acq,
          release_claim: recording_release,
          lease_goals: [{"g1", ["t"]}],
          lease_opts: [holder: "session-a", graph_source: source, lease_opts: lease_opts]
        )

      # The lease key, while held, blocks an overlapping acquirer. We assert the
      # lease is freed FIRST by probing it at the moment the claim release runs:
      # inside recording_release the lease must ALREADY be free.
      lease_key = hd(held.lease.leases).key

      probing_release = fn task_id ->
        # At claim-release time, the lease must already be released (freed first).
        send(log, {:lease_free_when_claim_releases?, Lease.Memory.peek(lease_key, lease_opts)})
        recording_release.(task_id)
      end

      held = %{held | release_claim: probing_release}
      :counters.add(order, 1, 1)

      assert :ok = Compose.release(held)

      # The lease was :free at the instant the claim release ran => lease-before-claim.
      assert_received {:lease_free_when_claim_releases?, :free}
      assert_received {:claim_released_at_step, 1}

      # And after release, BOTH locks are free: a fresh session takes the same
      # task + radius cleanly.
      {acq2, rel2} = claim_funs(store, "session-b", clock_opts)

      assert {:ok, _held2} =
               Compose.acquire(
                 task_id: "T-1",
                 acquire_claim: acq2,
                 release_claim: rel2,
                 lease_goals: [{"g2", ["t"]}],
                 lease_opts: [holder: "session-b", graph_source: source, lease_opts: lease_opts]
               )
    end

    test "with_boundary/2 releases lease-then-claim on EVERY exit (incl. raise)",
         %{store: store, clock_opts: clock_opts, lease_opts: lease_opts} do
      source = TermSource.new(%{"t" => ["lib/a.ex"]})
      {acq, rel} = claim_funs(store, "session-a", clock_opts)

      opts = [
        task_id: "T-1",
        acquire_claim: acq,
        release_claim: rel,
        lease_goals: [{"g1", ["t"]}],
        lease_opts: [holder: "session-a", graph_source: source, lease_opts: lease_opts]
      ]

      # Clean return: body runs, both locks freed afterward.
      assert {:ok, :edited} = Compose.with_boundary(opts, fn _held -> :edited end)

      # A crash mid-edit must still free both (lease before claim) -- otherwise the
      # overlapping radius AND the task would be stranded behind a dead session.
      assert_raise RuntimeError, "boom", fn ->
        Compose.with_boundary(opts, fn _held -> raise "boom" end)
      end

      # Both locks free after the crash: a fresh session takes the same task+radius.
      {acq2, rel2} = claim_funs(store, "session-b", clock_opts)

      assert {:ok, _held2} =
               Compose.acquire(
                 task_id: "T-1",
                 acquire_claim: acq2,
                 release_claim: rel2,
                 lease_goals: [{"g2", ["t"]}],
                 lease_opts: [holder: "session-b", graph_source: source, lease_opts: lease_opts]
               )
    end

    test "with_boundary/2 does NOT run the body when a lock is held",
         %{store: store, clock_opts: clock_opts, lease_opts: lease_opts} do
      source = TermSource.new(%{"t" => ["lib/a.ex"]})
      {acq_a, rel_a} = claim_funs(store, "session-a", clock_opts)
      {acq_b, rel_b} = claim_funs(store, "session-b", clock_opts)

      {:ok, held_a} =
        Compose.acquire(
          task_id: "T-1",
          acquire_claim: acq_a,
          release_claim: rel_a,
          lease_goals: [{"g1", ["t"]}],
          lease_opts: [holder: "session-a", graph_source: source, lease_opts: lease_opts]
        )

      ran? = :counters.new(1, [])

      assert {:error, :claim_held, %{task_id: "T-1"}} =
               Compose.with_boundary(
                 [
                   task_id: "T-1",
                   acquire_claim: acq_b,
                   release_claim: rel_b,
                   lease_goals: [{"g2", ["t"]}],
                   lease_opts: [holder: "session-b", graph_source: source, lease_opts: lease_opts]
                 ],
                 fn _held -> :counters.add(ran?, 1, 1) end
               )

      assert :counters.get(ran?, 1) == 0
      assert :ok = Compose.release(held_a)
    end
  end

  describe "missing required opts" do
    test "acquire/1 raises when a contract key is missing", %{lease_opts: lease_opts} do
      assert_raise ArgumentError, fn ->
        Compose.acquire(
          acquire_claim: fn _ -> :ok end,
          release_claim: fn _ -> :ok end,
          lease_goals: [{"g1", ["t"]}],
          lease_opts: [holder: "s", lease_opts: lease_opts]
        )
      end
    end
  end
end

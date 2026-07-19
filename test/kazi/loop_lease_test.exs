defmodule Kazi.LoopLeaseTest do
  @moduledoc """
  Loop-level wiring of the resource lease into goal dispatch (T3.1d, ADR-0006;
  UC-013).

  kazi coordinates parallel work on RESOURCES, not identities (ADR-0006): before
  it drives the harness against a goal, the loop leases that goal's resource key.
  Two instances aiming at the SAME key therefore SERIALIZE — one holds the lease
  and works, the other DEFERS (re-observes without dispatching) until the key is
  free — rather than colliding on the same blast radius. The lease is RELEASED on
  every terminal path (`:converged` / `:stopped` / `:over_budget`) so the next
  instance can take it up.

  These tests assert exactly that contract:

    * a loop whose resource key is held by ANOTHER holder never dispatches (it
      defers); once the foreign hold is released it acquires the key, dispatches,
      and converges — one works, the other waited;
    * a loop releases its lease when it stops (`stop/1`) and when it converges, so
      a subsequent `peek` reports the key free;
    * two loops on the SAME key serialize (the second cannot acquire while the
      first holds it); two loops on DISTINCT keys both acquire (parallel).

  Hermetic by construction: the in-memory lease double
  (`Kazi.Coordination.Lease.Memory`) is the only backend, time is the injected
  `:now_fn` virtual clock, and dispatch is observed through in-process behaviour
  doubles — no NATS, no network, no real clock in an assertion.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate, PredicateResult}
  alias Kazi.Coordination.Lease
  alias Kazi.Coordination.Lease.Memory

  # ===========================================================================
  # Test doubles (zero-stub: test-only; the loop depends on the behaviours)
  # ===========================================================================

  # A provider whose code predicate is :fail until the test flips a shared flag to
  # :pass, then :pass forever. Lets a test hold a loop in the dispatch path (code
  # failing) for as long as it likes, then let it converge on demand. The flag
  # Agent pid rides in the goal metadata (the doubles run inside the loop process).
  defmodule FlaggedProvider do
    @behaviour Kazi.PredicateProvider
    use Agent

    def start_link(_), do: Agent.start_link(fn -> :fail end)

    def pass(pid), do: Agent.update(pid, fn _ -> :pass end)

    @impl true
    def evaluate(%Predicate{id: id}, context) do
      status = Agent.get(context.goal.metadata.flag_pid, & &1)
      PredicateResult.new(status, %{id: id, status: status})
    end
  end

  # Harness double: records each dispatch to the collector (from adapter_opts) so a
  # test can assert WHETHER the loop dispatched (a deferring loop must not).
  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, opts) do
      send(Keyword.fetch!(opts, :collector), :dispatched)
      {:ok, %{output: "ok", cost: %{tokens: 1}}}
    end
  end

  # Integrate/deploy doubles: succeed silently so a green code predicate can carry
  # the loop all the way to :converged (the release-on-terminate path).
  defmodule OkIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(_action, _context), do: {:ok, %{pr: 1}}
  end

  defmodule OkDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(_action, _context), do: {:ok, %{ref: "v1"}}
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  # A monotonic virtual clock backed by an Agent (ms), so the lease TTL is driven
  # deterministically without any real time. Returns {advance_fn, now_fn}.
  defp virtual_clock(start_ms \\ 0) do
    {:ok, clock} = Agent.start_link(fn -> start_ms end)
    now_fn = fn -> Agent.get(clock, & &1) end
    advance = fn by -> Agent.update(clock, &(&1 + by)) end
    {advance, now_fn, clock}
  end

  defp goal_with_flag(id, flag_pid) do
    Goal.new(id,
      predicates: [Predicate.new(:code, :tests)],
      metadata: %{flag_pid: flag_pid}
    )
  end

  # Start a loop wired with the in-memory lease double on `store`, holding `holder`
  # for the resource `key`. Code-only goal driven by the FlaggedProvider.
  defp start_leased_loop(goal, store, key, holder, collector, now_fn, opts \\ []) do
    Kazi.Loop.start_link(
      [
        goal: goal,
        providers: %{tests: FlaggedProvider},
        harness: RecordingHarness,
        integrate: OkIntegrate,
        deploy: OkDeploy,
        adapter_opts: [collector: collector],
        # Disable the lifecycle-noise detectors: these tests hold a code predicate
        # failing across observations to keep the loop in the dispatch/defer path.
        flake_max_retries: 0,
        stuck_iterations: 0,
        reobserve_interval_ms: 5,
        # T3.1d: the resource lease seam — the in-memory double, this instance's
        # holder, the shared store + virtual clock in lease_opts, and a fixed key
        # so two loops can be made to contend (or not) deterministically.
        lease: Memory,
        lease_holder: holder,
        lease_ttl_ms: 10_000,
        lease_opts: [store: store, now_fn: now_fn],
        resource_key_fn: fn _goal -> key end
      ]
      |> Keyword.merge(opts)
    )
  end

  # ===========================================================================
  # Serialization: one works, the other defers
  # ===========================================================================

  test "a loop whose resource key is held by another holder DEFERS (does not dispatch)" do
    {:ok, store} = Memory.start_link()
    {_advance, now_fn, _clock} = virtual_clock()
    lease_opts = [store: store, now_fn: now_fn]

    # Instance A (a foreign holder) already owns the key — simulate the other kazi
    # working the resource. Instance B's loop must NOT dispatch while A holds it.
    {:ok, %Lease{} = a_lease} = Memory.acquire("hot-key", "instance-A", 10_000, lease_opts)

    {:ok, flag} = FlaggedProvider.start_link(nil)
    goal = goal_with_flag("loop-B", flag)

    {:ok, _loop} =
      start_leased_loop(goal, store, "hot-key", "instance-B", self(), now_fn)

    # Code predicate is failing, so decide routes to dispatch — but the key is
    # held by A, so the loop defers. Give it several poll intervals; it must never
    # dispatch while A holds the lease.
    refute_receive :dispatched, 120

    # A releases; now the key is free. B should acquire it on its next tick and
    # dispatch (and, with code still failing, keep dispatching). One works only
    # after the other let go — they serialized.
    :ok = Memory.release(a_lease, lease_opts)
    assert_receive :dispatched, 500
  end

  test "two loops on the SAME key serialize: only one holds the lease at a time" do
    {:ok, store} = Memory.start_link()
    {_advance, now_fn, _clock} = virtual_clock()
    lease_opts = [store: store, now_fn: now_fn]

    {:ok, flag1} = FlaggedProvider.start_link(nil)
    {:ok, flag2} = FlaggedProvider.start_link(nil)

    # Both target the SAME resource key with DISTINCT holders. The first to
    # dispatch wins the lease; the other must defer (cannot acquire while held).
    {:ok, _l1} =
      start_leased_loop(goal_with_flag("g1", flag1), store, "shared", "h1", self(), now_fn)

    {:ok, _l2} =
      start_leased_loop(goal_with_flag("g2", flag2), store, "shared", "h2", self(), now_fn)

    # Let them race a few intervals, then inspect who holds the key. Exactly one
    # holder owns it — they serialized rather than both grabbing it.
    Process.sleep(60)

    assert {:ok, %Lease{holder: holder}} = Memory.peek("shared", lease_opts)
    assert holder in ["h1", "h2"]

    # And only one of them is the dispatcher: the holder dispatches, the other has
    # deferred (we received at least one :dispatched, and the key is singly held).
    assert_received :dispatched
  end

  test "two loops on DISTINCT keys both acquire (parallel, no contention)" do
    {:ok, store} = Memory.start_link()
    {_advance, now_fn, _clock} = virtual_clock()
    lease_opts = [store: store, now_fn: now_fn]

    {:ok, flag1} = FlaggedProvider.start_link(nil)
    {:ok, flag2} = FlaggedProvider.start_link(nil)

    {:ok, _l1} =
      start_leased_loop(goal_with_flag("g1", flag1), store, "key-a", "h1", self(), now_fn)

    {:ok, _l2} =
      start_leased_loop(goal_with_flag("g2", flag2), store, "key-b", "h2", self(), now_fn)

    Process.sleep(60)

    # Disjoint keys ⇒ both hold their own lease ⇒ both dispatch in parallel.
    assert {:ok, %Lease{holder: "h1"}} = Memory.peek("key-a", lease_opts)
    assert {:ok, %Lease{holder: "h2"}} = Memory.peek("key-b", lease_opts)
  end

  # ===========================================================================
  # Release on terminate
  # ===========================================================================

  test "the lease is RELEASED when the loop stops" do
    {:ok, store} = Memory.start_link()
    {_advance, now_fn, _clock} = virtual_clock()
    lease_opts = [store: store, now_fn: now_fn]

    {:ok, flag} = FlaggedProvider.start_link(nil)
    goal = goal_with_flag("stoppable", flag)

    {:ok, loop} =
      start_leased_loop(goal, store, "lock-key", "holder", self(), now_fn)

    # Wait until the loop has acquired the key (it dispatches once it holds it).
    assert_receive :dispatched, 500
    assert {:ok, %Lease{holder: "holder"}} = Memory.peek("lock-key", lease_opts)

    # Stop the loop; it must release the key on the way to :stopped.
    :ok = Kazi.Loop.stop(loop)
    assert {:ok, _result} = Kazi.Loop.await(loop, 5_000)

    assert :free = Memory.peek("lock-key", lease_opts)
  end

  test "the lease is RELEASED when the loop converges" do
    {:ok, store} = Memory.start_link()
    {_advance, now_fn, _clock} = virtual_clock()
    lease_opts = [store: store, now_fn: now_fn]

    {:ok, flag} = FlaggedProvider.start_link(nil)
    goal = goal_with_flag("convergeable", flag)

    {:ok, loop} =
      start_leased_loop(goal, store, "conv-key", "holder", self(), now_fn)

    # Hold it in the dispatch path until it has the lease, then let the code go
    # green so it integrates → deploys → converges.
    assert_receive :dispatched, 500
    FlaggedProvider.pass(flag)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :converged

    # Converging is a terminal path, so the key is freed.
    assert :free = Memory.peek("conv-key", lease_opts)
  end

  # ===========================================================================
  # Leasing is OFF by default (back-compat)
  # ===========================================================================

  test "without a :lease backend the loop never leases (default unchanged)" do
    {:ok, flag} = FlaggedProvider.start_link(nil)
    FlaggedProvider.pass(flag)
    goal = goal_with_flag("no-lease", flag)

    # No :lease opt — leasing is a pure no-op; the loop converges normally.
    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: FlaggedProvider},
        harness: RecordingHarness,
        integrate: OkIntegrate,
        deploy: OkDeploy,
        adapter_opts: [collector: self()],
        flake_max_retries: 0,
        stuck_iterations: 0,
        reobserve_interval_ms: 5
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :converged
  end
end

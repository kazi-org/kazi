defmodule Kazi.Bus.DiscoveryAuditTest do
  @moduledoc """
  #1649: the first sweep of EVERY bus verb through the REAL discovery path.

  ## What this is

  `Kazi.Bus.with_conn/2` short-circuits to `run(conn, fun, _)` whenever
  `opts[:conn]` is supplied, and every other bus test supplies one. So
  `Probe.probe` → `Probe.ping` → `check_protocol_skew` → `Gnat.start_link` →
  `run` had never been executed by the suite. These tests pass `sock_path:` and
  NO `conn:`, so each verb genuinely performs discovery and attempts a
  connection to the peer the stub daemon names.

  This is an AUDIT, not a regression suite. The path has never been exercised,
  so a green run means "the first time we looked, it held" — NOT "there is
  nothing else here". Anything it surfaces is filed separately (#1649 scope).

  ## The contract every verb must honour

  `Kazi.Bus` documents that a bus call DEGRADES on an unreachable bus rather
  than taking its caller down. Both halves are asserted per verb, against both
  peer states:

    1. it returns a value (an `{:error, _}` degrade, or the verb's documented
       best-effort fallback) rather than raising;
    2. it does NOT kill a caller that does not trap exits — the #1606 shape,
       where `Gnat.start_link/1`'s link killed the velocity pass upstream of the
       un-linked `run/3`;
    3. it returns within a bound rather than hanging.

  Callers are deliberately bare `spawn_monitor`'d processes with NO
  `trap_exit`, because that is the shape #1606 actually killed.
  """
  use ExUnit.Case, async: false

  alias Kazi.Bus
  alias Kazi.TestSupport.BusPeer

  # Short, so a blackholing peer bounds fast. `Kazi.Bus` adds its own connect
  # grace on top of this.
  @call_timeout_ms 800

  # Generous enough to cover the call bound + connect grace + scheduling, tight
  # enough that a genuine hang fails rather than stalling the suite.
  @verdict_timeout_ms 8_000

  # Every PUBLIC verb that routes through `with_conn/2`. Derived by mapping each
  # `with_conn(opts, ...)` call site to its enclosing public function; `scope/1`
  # and `attention_topic/1` are NOT here (they are pure helpers that never reach
  # the bus, despite sitting near a call site).
  @verbs ~w(
    post tell who board join join_derived leave name assign_name
    name_bindings read_since status get waiting_on_operator? watch
  )

  # Drive `fun` in a NON-TRAPPING process and assert the #1606 contract: it
  # returns a value, it does not take the caller down, and it does so in time.
  defp assert_degrades(label, fun) do
    parent = self()

    {pid, ref} = spawn_monitor(fn -> send(parent, {:returned, fun.()}) end)

    receive do
      {:returned, value} ->
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @verdict_timeout_ms
        value

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("""
        #{label}: the caller was KILLED instead of degrading (#1606 shape).

        A bus verb must degrade on an unreachable bus, never take its caller
        down. A non-trapping caller (the velocity pass shape) died with:

            #{inspect(reason)}
        """)
    after
      @verdict_timeout_ms ->
        Process.exit(pid, :kill)

        flunk(
          "#{label}: HUNG — no verdict within #{@verdict_timeout_ms}ms (the bound did not fire)"
        )
    end
  end

  # One clause per verb, so each is called with real arguments through the real
  # discovery path (`sock_path:`, never `conn:`).
  defp call_verb("post", o),
    do: Bus.post("fact", ~s({"probe":true}), [topic: "session:probe"] ++ o)

  defp call_verb("tell", o), do: Bus.tell("someone", "hello", o)
  defp call_verb("who", o), do: Bus.who(o)
  defp call_verb("board", o), do: Bus.board(o)
  defp call_verb("join", o), do: Bus.join("some-team", o)
  defp call_verb("join_derived", o), do: Bus.join_derived(o)
  defp call_verb("leave", o), do: Bus.leave(o)
  defp call_verb("name", o), do: Bus.name("some-nickname", o)
  defp call_verb("assign_name", o), do: Bus.assign_name("some-team", o)
  defp call_verb("name_bindings", o), do: Bus.name_bindings(o)
  defp call_verb("read_since", o), do: Bus.read_since(0, o)
  defp call_verb("status", o), do: Bus.status(1, o)
  defp call_verb("get", o), do: Bus.get(1, o)
  defp call_verb("waiting_on_operator?", o), do: Bus.waiting_on_operator?(o)
  # `watch` owns a long internal bound by design; pin it short so the blackhole
  # case bounds inside this test rather than its default wait.
  defp call_verb("watch", o), do: Bus.watch([timeout: 1] ++ o)

  describe "every bus verb, through REAL discovery, against a BLACKHOLING peer" do
    for verb <- @verbs do
      @verb verb
      test "#{verb} degrades and does not kill its caller" do
        opts = [sock_path: BusPeer.blackhole(), call_timeout_ms: @call_timeout_ms]
        value = assert_degrades("#{@verb} (blackhole)", fn -> call_verb(@verb, opts) end)

        refute match?({:ok, _}, value),
               "#{@verb}: an unreachable peer must not report success, got #{inspect(value)}"
      end
    end
  end

  describe "every bus verb, through REAL discovery, against a REFUSING peer" do
    for verb <- @verbs do
      @verb verb
      test "#{verb} degrades and does not kill its caller" do
        opts = [sock_path: BusPeer.refusing(), call_timeout_ms: @call_timeout_ms]
        value = assert_degrades("#{@verb} (refusing)", fn -> call_verb(@verb, opts) end)

        refute match?({:ok, _}, value),
               "#{@verb}: a refused peer must not report success, got #{inspect(value)}"
      end
    end
  end

  # These guard the AUDIT ITSELF. Without them the sweep above could silently
  # decay into testing nothing, which is exactly how #1649 arose.
  #
  # They assert on TIMING, so they use `BusPeer.stalling/0` (a local
  # never-accepting listener) rather than `blackhole/0`. `blackhole/0` relies on
  # TEST-NET being DROPPED, which is a property of the network rather than of the
  # address — on a network that answers ICMP-unreachable it errors fast, and these
  # comparisons would flake. `stalling/0` blocks deterministically with no network
  # involved. The per-verb sweep above is unaffected either way: it asserts
  # "degrades, does not kill, within a bound", which holds whether TEST-NET drops
  # or refuses.
  describe "the sweep really reaches discovery (guards against a vacuous audit)" do
    # THE TRAP: `{:error, :no_daemon}` is returned BOTH when there is no socket
    # at all (discovery never starts) AND when discovery ran and the connection
    # failed. So the RETURN VALUE alone cannot prove the sweep exercised
    # anything — asserting on it would be the same false comfort #1649 is about.
    # Timing is the discriminator: a peer that blackholes must cost materially
    # more than a path that never dialled at all.
    test "a stalling peer costs materially more than never dialling (so the connect IS attempted)" do
      no_socket = "/tmp/kazi-absent-#{System.unique_integer([:positive])}.sock"
      opts = fn sock -> [sock_path: sock, call_timeout_ms: @call_timeout_ms] end

      {control_us, control} = :timer.tc(fn -> Bus.who(opts.(no_socket)) end)
      {blackhole_us, blackholed} = :timer.tc(fn -> Bus.who(opts.(BusPeer.stalling())) end)

      # Both degrade to the SAME value — documenting the trap in an assertion so
      # nobody later "simplifies" this file down to value checks.
      assert control == {:error, :no_daemon}
      assert blackholed == {:error, :no_daemon}

      assert blackhole_us > control_us * 5,
             """
             The blackholing peer (#{div(blackhole_us, 1000)}ms) was not materially slower than
             never dialling at all (#{div(control_us, 1000)}ms). Both return {:error, :no_daemon},
             so if the timings converge the sweep is no longer proving it reaches
             Gnat.start_link — it would pass even if discovery never ran.
             """
    end

    test "a stalling peer BLOCKS to the bound; a refusing peer errors fast" do
      opts = fn sock -> [sock_path: sock, call_timeout_ms: @call_timeout_ms] end

      {blackhole_us, _} = :timer.tc(fn -> Bus.who(opts.(BusPeer.stalling())) end)
      {refuse_us, _} = :timer.tc(fn -> Bus.who(opts.(BusPeer.refusing())) end)

      # The refusing peer answers well inside the call bound; the blackholing
      # one has to wait for it. If these ever converge, the fixtures have
      # stopped modelling two distinct states and the sweep only tests one.
      assert refuse_us < @call_timeout_ms * 1_000,
             "refusing peer took #{div(refuse_us, 1000)}ms — expected a fast error"

      assert blackhole_us > refuse_us,
             "blackhole (#{div(blackhole_us, 1000)}ms) should outlast refuse (#{div(refuse_us, 1000)}ms)"
    end
  end
end

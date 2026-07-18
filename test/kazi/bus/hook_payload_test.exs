defmodule Kazi.Bus.HookPayloadTest do
  @moduledoc """
  T55.9 (ADR-0071 decisions 2/4/5): the payload behind `kazi bus hook <event>`.

  UNTAGGED tests (always run, no NATS needed): the advisory-framing contract,
  the silent no-op paths (unknown event, no daemon), and -- the single most
  important correctness property -- the hard wall-clock bound against a HUNG
  daemon (a socket that accepts the connection but never answers).

  `:nats`-TAGGED tests (excluded by default; `NATS_URL` required) exercise the
  `session-start` payload against a live JetStream server with a conn injected
  directly: the board + team membership visible in a real `who`.

  The `turn` payload is NOT tested here: T55.7 (ADR-0072 d5) routed it through
  the daemon's control socket (`Kazi.Bus.read_digest/1`), so a bare `conn:` no
  longer reaches it -- its traffic/quiet/verbatim/bounded coverage lives in
  `Kazi.Bus.DaemonDigestTest`, which boots a real daemon, the only place the
  daemon-assembled digest can be exercised.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.Bus
  alias Kazi.Bus.Hook

  # ===========================================================================
  # Untagged: the advisory-framing contract (ADR-0067 point 7)
  # ===========================================================================

  describe "advisory framing" do
    test "the framing marks the block untrusted, advisory, and non-authoritative" do
      advisory = Hook.advisory()

      assert advisory =~ "UNTRUSTED"
      assert advisory =~ "background context"
      assert advisory =~ "NEVER"
      assert advisory =~ "command channel"
      assert advisory =~ "no authority"
      assert advisory =~ "ADR-0067 point 7"
    end

    test "banner and footer bracket the block" do
      assert Hook.banner() =~ "kazi session bus"
      assert Hook.footer() =~ "kazi session bus"
    end
  end

  # ===========================================================================
  # Untagged: silent no-op paths
  # ===========================================================================

  describe "run/2 is a silent exit 0 without a live daemon" do
    test "an unknown event prints nothing and never touches the daemon" do
      out = capture_io(fn -> assert Hook.run("frobnicate") == 0 end)
      assert out == ""
    end

    test "turn with no daemon injects nothing and exits 0" do
      out = capture_io(fn -> assert Hook.run("turn", sock_path: missing_sock()) == 0 end)
      assert out == ""
    end

    test "session-start with no daemon injects nothing and exits 0" do
      out = capture_io(fn -> assert Hook.run("session-start", sock_path: missing_sock()) == 0 end)
      assert out == ""
    end

    test "notification with no daemon prints nothing and exits 0 (T60.3)" do
      out =
        capture_io(fn ->
          assert Hook.run("notification", sock_path: missing_sock(), summary: "x") == 0
        end)

      assert out == ""
    end

    test "payload/2 returns :silent for an unknown event with no work done" do
      assert Hook.payload("nope", []) == :silent
    end
  end

  # ===========================================================================
  # Untagged: T60.3 (issue #1156) -- attention_topic/1's pure sanitization rule
  # ===========================================================================

  describe "attention_topic/1" do
    test "prefixes the session with attention-" do
      assert Hook.attention_topic("worker-1") == "attention-worker-1"
    end

    test "sanitizes any char outside [A-Za-z0-9._-] to a dash, without adding extra dots" do
      assert Hook.attention_topic("worker@host/1") == "attention-worker-host-1"
      assert Hook.attention_topic("s-abc123.def_ghi") == "attention-s-abc123.def_ghi"
    end
  end

  # ===========================================================================
  # Untagged: T60.3 -- notification/1 ALWAYS returns :silent (posts outward only)
  # ===========================================================================

  describe "notification/1 always returns :silent" do
    test ":silent even when the post would succeed (no daemon here, but the CONTRACT holds regardless)" do
      assert Hook.notification(sock_path: missing_sock(), summary: "blocked on approval") ==
               :silent
    end

    test ":silent even with malformed opts / no summary / no stdin available" do
      capture_io("", fn ->
        assert Hook.notification(sock_path: missing_sock()) == :silent
      end)
    end
  end

  # ===========================================================================
  # Untagged: the HARD wall-clock bound against a HUNG daemon
  # ===========================================================================

  describe "run/2 is bounded even against a HUNG daemon" do
    test "a socket that accepts but never replies still exits 0 silently within the bound" do
      path = stalled_socket!()

      {elapsed_us, out} =
        :timer.tc(fn ->
          capture_io(fn -> assert Hook.run("turn", sock_path: path) == 0 end)
        end)

      # Zero bytes injected: a hung daemon must deliver NOTHING to the session.
      assert out == ""

      # The hook's own bound is ~2s; a real hang (no bound) would run into a
      # connect/recv default far longer. 4s proves it is bounded, not hanging.
      assert elapsed_us < 4_000_000,
             "hook took #{div(elapsed_us, 1000)}ms against a hung daemon -- expected < 4000ms"
    end
  end

  # ===========================================================================
  # Untagged: the PER-EVENT wall-clock bound (issue #1295)
  #
  # session-start is a one-shot boot whose full-board drain can run seconds under
  # a busy backlog, so it gets a larger bound; turn is the per-turn hot path and
  # MUST stay at the tight 2s bound. These are proven with an injected slow
  # payload (`:payload_fun`) so the SAME slow work succeeds under session-start
  # and is killed under turn -- no live daemon needed.
  # ===========================================================================

  describe "per-event timeout bound" do
    test "turn keeps the tight 2s bound and session-start gets a larger one" do
      # The hot-path invariant issue #1295 must NOT weaken: turn stays 2000ms.
      assert Hook.timeout_ms("turn") == 2_000
      # An unknown event also gets the tight bound (never the generous one).
      assert Hook.timeout_ms("frobnicate") == 2_000
      # session-start tolerates a slow one-shot board; it is strictly larger and
      # comfortably covers the ~9.7s board drain observed live (issue #1295).
      assert Hook.timeout_ms("session-start") > 2_000
      assert Hook.timeout_ms("session-start") >= 10_000
    end

    test "session-start tolerates a slow (3s) board and injects it, non-silent" do
      slow = slow_payload_fun(3_000, {:emit, "SLOW-BOARD-CONTENT\n"})

      {elapsed_us, out} =
        :timer.tc(fn ->
          capture_io(fn ->
            assert Hook.run("session-start", payload_fun: slow) == 0
          end)
        end)

      # The board that would have been shutdown-to-:silent under the old 2s bound
      # now actually reaches the session.
      assert out =~ "SLOW-BOARD-CONTENT"
      # It really waited for the slow payload rather than short-circuiting.
      assert elapsed_us >= 3_000_000
      # And it is still bounded well under the 15s ceiling.
      assert elapsed_us < 14_000_000
    end

    test "turn kills the SAME slow (3s) payload at the 2s bound -- injects nothing" do
      slow = slow_payload_fun(3_000, {:emit, "SHOULD-NOT-APPEAR\n"})

      {elapsed_us, out} =
        :timer.tc(fn ->
          capture_io(fn -> assert Hook.run("turn", payload_fun: slow) == 0 end)
        end)

      # A payload slower than the hot-path bound is shut down: nothing injected.
      assert out == ""
      # It was cut at ~2s, not allowed to run the full 3s.
      assert elapsed_us < 3_000_000,
             "turn ran #{div(elapsed_us, 1000)}ms -- the 2s hot-path bound must not be weakened"
    end
  end

  # ===========================================================================
  # :nats-tagged (excluded by default; NATS_URL required)
  # ===========================================================================

  @moduletag :nats_group

  describe "against a real NATS JetStream server" do
    @describetag :nats

    setup do
      {host, port} = parse_nats_url(System.fetch_env!("NATS_URL"))
      {:ok, conn} = Gnat.start_link(%{host: host, port: port})
      on_exit(fn -> if Process.alive?(conn), do: Gnat.stop(conn) end)
      :ok = Kazi.Bus.Provision.provision(conn)
      %{conn: conn}
    end

    test "session-start injects the board and the session appears in `who` with its team",
         %{conn: conn} do
      session = unique_session()
      opts = [conn: conn, session: session, scope: "machine"]

      assert {:emit, block} = Hook.session_start(opts)

      team = Bus.project_id()
      assert block =~ Hook.banner()
      assert block =~ "joined team #{team}"
      assert block =~ "roster"

      assert {:ok, roster} = Bus.who(opts)
      row = Enum.find(roster, &(&1["session"] == session))
      assert row, "the session-start session must appear in a real `who`"
      assert row["team"] == team
    end

    # T60.3 (issue #1156): notification posts a waiting-on-operator fact on
    # `attention-<session>`, always returning :silent (it never injects).
    test "notification posts a waiting-on-operator fact on attention-<session>, returns :silent",
         %{conn: conn} do
      session = unique_session()
      opts = [conn: conn, session: session, scope: "machine", summary: "needs a decision"]

      assert Hook.notification(opts) == :silent

      {:ok, board} = Bus.board(opts)
      assert [entry] = board["attention"]
      assert entry["session"] == session
      assert entry["summary"] == "needs a decision"
    end

    # T60.3: turn clears (posts "none" on) the session's attention topic ONLY
    # when a live waiting fact exists -- best-effort and rescue-wrapped, so it
    # never disturbs the digest path itself.
    test "turn clears a previously-waiting session's attention fact", %{conn: conn} do
      session = unique_session()
      opts = [conn: conn, session: session, scope: "machine", summary: "blocked"]

      assert Hook.notification(opts) == :silent
      {:ok, board_before} = Bus.board(opts)
      assert [_waiting] = board_before["attention"]

      Hook.turn(opts)

      {:ok, board_after} = Bus.board(opts)
      assert board_after["attention"] == []
    end

    # T60.3 / #1392 REGRESSION GUARD: a turn on a session that was NEVER waiting
    # must post NOTHING. An unconditional per-turn `none` clear added a bus
    # message on every turn, which inflated a pinned digest message-count
    # assertion (daemon_digest_test) and would spam the bus in production. Using
    # a fresh, isolated scope, `total_facts` after the turn must be exactly 0.
    test "turn posts nothing when the session was never waiting (#1392 regression)",
         %{conn: conn} do
      session = unique_session()
      scope = "attn-regress-#{System.unique_integer([:positive])}"
      opts = [conn: conn, session: session, scope: scope]

      Hook.turn(opts)

      {:ok, board} = Bus.board(opts)
      assert board["attention"] == []
      assert board["total_facts"] == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A payload that sleeps `ms` then returns `result`, standing in for a real but
  # SLOW board/digest so a test can drive `run/2`'s per-event bound around it.
  defp slow_payload_fun(ms, result) do
    fn _event, _opts ->
      Process.sleep(ms)
      result
    end
  end

  defp missing_sock,
    do:
      Path.join(System.tmp_dir!(), "kazi_hook_missing_#{System.unique_integer([:positive])}.sock")

  # A stalled control socket: it accepts the connection (so `Probe.probe/1`
  # classifies it `:alive`) but never writes a reply, standing in for a daemon
  # that is HUNG rather than merely down.
  defp stalled_socket! do
    path =
      Path.join(System.tmp_dir!(), "kazi_hook_stalled_#{System.unique_integer([:positive])}.sock")

    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :line, active: false, ifaddr: {:local, path}])

    acceptor = spawn(fn -> stalled_accept(listen) end)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
      File.rm(path)
    end)

    path
  end

  defp stalled_accept(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, _sock} -> stalled_accept(listen)
      {:error, _closed} -> :ok
    end
  end

  defp unique_session, do: "hook-#{System.unique_integer([:positive])}"

  defp parse_nats_url("nats://" <> hostport), do: parse_nats_url(hostport)

  defp parse_nats_url(hostport) do
    case String.split(hostport, ":") do
      [host, port] -> {host, String.to_integer(port)}
      [host] -> {host, 4222}
    end
  end
end

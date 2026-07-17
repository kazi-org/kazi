defmodule Kazi.Bus.HookPayloadTest do
  @moduledoc """
  T55.9 (ADR-0071 decisions 2/4/5): the payload behind `kazi bus hook <event>`.

  UNTAGGED tests (always run, no NATS needed): the advisory-framing contract,
  the silent no-op paths (unknown event, no daemon), and -- the single most
  important correctness property -- the hard wall-clock bound against a HUNG
  daemon (a socket that accepts the connection but never answers).

  `:nats`-TAGGED tests (excluded by default; `NATS_URL` required) exercise the
  real payload against a live JetStream server with a conn injected directly:
  the bounded/provenance-stamped digest on traffic, ZERO BYTES on a quiet bus,
  and the session-start board + team membership visible in a real `who`.
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

    test "payload/2 returns :silent for an unknown event with no work done" do
      assert Hook.payload("nope", []) == :silent
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

    test "a bus WITH traffic injects a bounded, provenance-stamped digest", %{conn: conn} do
      session = unique_session()
      opts = [conn: conn, session: session, scope: "machine"]

      # Presence, then a directed tell to self -- a `msg` renders verbatim, so
      # its text AND provenance land in the digest.
      assert {:ok, _} = Bus.who(opts)
      drain(opts)
      text = "directed #{session}"
      assert {:ok, _} = Bus.tell(session, text, conn: conn, scope: "machine")

      assert {:emit, block} = Hook.turn(opts)

      assert block =~ Hook.banner()
      assert block =~ Hook.advisory()
      assert block =~ Hook.footer()
      assert block =~ text
      # provenance stamp: the originating session id is on the verbatim line.
      assert block =~ session
    end

    test "the injected digest is bounded to the T55.1 line cap", %{conn: conn} do
      session = unique_session()
      opts = [conn: conn, session: session, scope: "machine"]

      assert {:ok, _} = Bus.who(opts)
      drain(opts)

      for i <- 1..(Kazi.Bus.Digest.max_lines() + 20) do
        assert :ok = Bus.post("note", "n#{i}", Keyword.put(opts, :topic, "t#{i}"))
      end

      assert {:emit, block} = Hook.turn(opts)
      body = block |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "  "))
      # header line + at most max_lines rendered digest lines.
      assert length(body) <= Kazi.Bus.Digest.max_lines()
    end

    test "a QUIET bus injects ZERO BYTES", %{conn: conn} do
      session = unique_session()
      opts = [conn: conn, session: session, scope: "machine"]

      assert {:ok, _} = Bus.who(opts)
      drain(opts)

      # No new traffic since the drain: payload is :silent and run writes 0 bytes.
      assert Hook.turn(opts) == :silent

      out = capture_io(fn -> assert Hook.run("turn", opts) == 0 end)
      assert byte_size(out) == 0
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
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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

  # Drains the caller's durable cursor to empty (L-0040: `read` pulls in batches,
  # and a fresh consumer replays broadcast history) so a following `turn` sees
  # only what is posted AFTER.
  defp drain(opts) do
    case Bus.read(opts) do
      {:ok, []} -> :ok
      {:ok, _} -> drain(opts)
      {:error, _} -> :ok
    end
  end

  defp parse_nats_url("nats://" <> hostport), do: parse_nats_url(hostport)

  defp parse_nats_url(hostport) do
    case String.split(hostport, ":") do
      [host, port] -> {host, String.to_integer(port)}
      [host] -> {host, 4222}
    end
  end
end

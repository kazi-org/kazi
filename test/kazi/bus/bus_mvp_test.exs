defmodule Kazi.Bus.MvpTest do
  @moduledoc """
  T51.2 (ADR-0067 decision points 2-4): the session-bus MVP's client contract.

  UNTAGGED tests (always run, no NATS needed): the no-daemon error path,
  the 1024-byte client-side cap, project-id derivation, and
  `Kazi.Bus.Digest.summarize/1`'s pure rendering rule.

  `:nats`-TAGGED tests mirror `test/kazi/coordination/lease/nats_test.exs`:
  excluded by default, run only when `NATS_URL` is set. Each test provisions
  for itself (`Kazi.Bus.Provision.provision/1`) and passes `opts[:conn]`
  directly to `Kazi.Bus`, so it exercises the client against a real
  JetStream server WITHOUT needing a running `kazi daemon`.
  """
  use ExUnit.Case, async: false

  alias Kazi.Bus
  alias Kazi.Bus.Digest

  # ===========================================================================
  # Untagged: no-daemon error path
  # ===========================================================================

  describe "no daemon" do
    test "post/tell/read/who all report {:error, :no_daemon} against a missing socket" do
      opts = [sock_path: "/tmp/kazi_bus_test_missing_#{System.unique_integer([:positive])}.sock"]

      assert {:error, :no_daemon} = Bus.post("note", "hi", opts)
      assert {:error, :no_daemon} = Bus.tell("someone", "hi", opts)
      assert {:error, :no_daemon} = Bus.read(opts)
      assert {:error, :no_daemon} = Bus.who(opts)
    end
  end

  # ===========================================================================
  # Untagged: the 1024-byte client-side cap
  # ===========================================================================

  describe "oversize post" do
    test "text over 1024 bytes is rejected before any connection attempt" do
      oversize = String.duplicate("x", 1025)

      assert {:error, {:text_too_large, 1024}} = Bus.post("note", oversize, conn: :unused)
    end

    test "exactly 1024 bytes is NOT rejected on size (a missing conn surfaces a different error)" do
      exactly_cap = String.duplicate("x", 1024)

      assert {:error, reason} = Bus.post("note", exactly_cap, sock_path: "/tmp/nope.sock")
      assert reason != {:text_too_large, 1024}
    end
  end

  # ===========================================================================
  # Untagged: project-id derivation
  # ===========================================================================

  describe "project_id/0" do
    test "slugs the git toplevel into a lowercase, hyphenated id" do
      id = Bus.project_id()

      assert id == String.downcase(id)
      refute id =~ ~r{[^a-z0-9-]}
      assert id != ""
    end
  end

  # ===========================================================================
  # Untagged: Digest.summarize/1
  # ===========================================================================

  describe "Digest.summarize/1" do
    test "empty input yields empty output" do
      assert Digest.summarize([]) == %{verbatim: [], digest: []}
    end

    test "directed (msg) and interrupt-severity messages render verbatim" do
      messages = [
        %{kind: "msg", topic: "alice", text: "ping alice", sev: "info"},
        %{kind: "note", topic: "ci", text: "build red", sev: "interrupt"}
      ]

      result = Digest.summarize(messages)
      assert length(result.verbatim) == 2
      assert result.digest == []
    end

    test "everything else collapses into count digest lines, most-frequent first" do
      messages =
        List.duplicate(%{kind: "note", topic: "ci", text: "x", sev: "info"}, 3) ++
          List.duplicate(%{kind: "note", topic: "deploy", text: "y", sev: "info"}, 1)

      result = Digest.summarize(messages)
      assert result.verbatim == []
      assert result.digest == ["3 note/ci", "1 note/deploy"]
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

    # `read/1`'s consumer replays the whole (broadcast) `KAZI_BUS` stream
    # history on its first creation, per JetStream's default `deliver_policy:
    # :all` -- so a fresh session's first read can see prior tests' posts
    # too. Assertions below look for the OWN post by its unique text instead
    # of asserting the returned list is a singleton.
    test "post -> read round trip returns the message with provenance headers", %{conn: conn} do
      session = unique_session()
      text = "hello bus #{session}"
      opts = [conn: conn, session: session, scope: "machine"]

      assert :ok = Bus.post("note", text, Keyword.put(opts, :topic, "greet"))
      assert {:ok, messages} = Bus.read(opts)

      assert msg = Enum.find(messages, fn m -> m.text == text end)
      assert msg.kind == "note"
      assert msg.topic == "greet"
      assert msg.session == session
      assert is_binary(msg.machine)
      assert is_binary(msg.ts)
    end

    test "a second read returns nothing new (durable cursor)", %{conn: conn} do
      session = unique_session()
      text = "once #{session}"
      opts = [conn: conn, session: session, scope: "machine"]

      assert :ok = Bus.post("note", text, opts)
      assert {:ok, first_messages} = Bus.read(opts)
      assert Enum.any?(first_messages, fn m -> m.text == text end)

      assert {:ok, second_messages} = Bus.read(opts)
      refute Enum.any?(second_messages, fn m -> m.text == text end)
    end

    test "tell reaches only the named session's consumer", %{conn: conn} do
      session_a = unique_session()
      session_b = unique_session()
      opts_a = [conn: conn, session: session_a, scope: "machine"]
      opts_b = [conn: conn, session: session_b, scope: "machine"]

      assert :ok = Bus.tell(session_a, "for A only", conn: conn, scope: "machine")

      assert {:ok, messages_a} = Bus.read(opts_a)
      assert Enum.any?(messages_a, fn m -> m.kind == "msg" and m.text == "for A only" end)

      assert {:ok, messages_b} = Bus.read(opts_b)
      refute Enum.any?(messages_b, fn m -> m.kind == "msg" and m.text == "for A only" end)
    end

    # Issue #1065: a `tell` published under a different scope than the
    # reader's used to be stored but never delivered -- silently.
    test "a cross-scope tell still reaches the named session (issue #1065)", %{conn: conn} do
      recipient = unique_session()

      assert :ok = Bus.tell(recipient, "cross-scope #{recipient}", conn: conn, scope: "project")

      assert {:ok, messages} = Bus.read(conn: conn, session: recipient, scope: "machine")

      assert Enum.any?(messages, fn m ->
               m.kind == "msg" and m.text == "cross-scope #{recipient}"
             end)
    end

    test "a same-scope tell is delivered exactly once despite the second consumer (issue #1065)",
         %{conn: conn} do
      recipient = unique_session()
      text = "exactly-once #{recipient}"

      assert :ok = Bus.tell(recipient, text, conn: conn, scope: "machine")

      assert {:ok, messages} = Bus.read(conn: conn, session: recipient, scope: "machine")
      assert Enum.count(messages, fn m -> m.text == text end) == 1
    end

    test "who reflects an upserted presence entry", %{conn: conn} do
      session = unique_session()
      opts = [conn: conn, session: session, scope: "machine"]

      assert :ok = Bus.post("note", "presence ping", opts)
      assert {:ok, sessions} = Bus.who(opts)

      assert Enum.any?(sessions, fn s -> s["session"] == session end)
    end

    test "oversize post is rejected client-side (never reaches NATS)", %{conn: conn} do
      oversize = String.duplicate("x", 1025)

      assert {:error, {:text_too_large, 1024}} =
               Bus.post("note", oversize, conn: conn, session: unique_session())
    end
  end

  defp unique_session, do: "bus_mvp_test_#{System.unique_integer([:positive])}"

  @doc false
  def parse_nats_url(url) do
    uri = URI.parse(url)
    {uri.host || "127.0.0.1", uri.port || 4222}
  end
end

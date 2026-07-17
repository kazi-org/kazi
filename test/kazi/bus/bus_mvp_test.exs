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
    test "text over 64 KiB is rejected before any connection attempt" do
      oversize = String.duplicate("x", 65_537)

      assert {:error, {:text_too_large, 65_536}} = Bus.post("note", oversize, conn: :unused)
    end

    test "exactly 64 KiB is NOT rejected on size (a missing conn surfaces a different error)" do
      exactly_cap = String.duplicate("x", 65_536)

      assert {:error, reason} = Bus.post("note", exactly_cap, sock_path: "/tmp/nope.sock")
      assert reason != {:text_too_large, 65_536}
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

      assert entry = Enum.find(sessions, fn s -> s["session"] == session end)
      # issue #1102: the entry is attributable to a machine, so a shared
      # cross-machine roster can tell a local session from a remote one.
      assert is_binary(entry["machine"]) and entry["machine"] != ""
    end

    test "oversize post is rejected client-side (never reaches NATS)", %{conn: conn} do
      oversize = String.duplicate("x", 65_537)

      assert {:error, {:text_too_large, 65_536}} =
               Bus.post("note", oversize, conn: conn, session: unique_session())
    end

    test "a multi-KB document-sized post round-trips (issue: 1024-byte cap)", %{conn: conn} do
      session = unique_session()
      text = "doc #{session} " <> String.duplicate("y", 8_000)
      opts = [conn: conn, session: session, scope: "machine"]

      assert :ok = Bus.post("note", text, opts)
      assert {:ok, messages} = Bus.read(opts)
      assert Enum.any?(messages, fn m -> m.text == text end)
    end

    # ---- teams (#1069) -------------------------------------------------

    test "join -> who --team lists the member with its team; leave clears it", %{conn: conn} do
      session = unique_session()
      team = "team_#{System.unique_integer([:positive])}"
      opts = [conn: conn, session: session, scope: "machine"]

      assert :ok = Bus.join(team, opts)
      assert {:ok, members} = Bus.who(opts ++ [who_team: team])
      assert Enum.any?(members, fn s -> s["session"] == session and s["team"] == team end)

      # membership survives an unrelated bus call's presence refresh
      assert :ok = Bus.post("note", "still here #{session}", opts)
      assert {:ok, members2} = Bus.who(opts ++ [who_team: team])
      assert Enum.any?(members2, fn s -> s["session"] == session and s["team"] == team end)

      assert :ok = Bus.leave(opts)
      assert {:ok, members3} = Bus.who(opts ++ [who_team: team])
      refute Enum.any?(members3, fn s -> s["session"] == session end)
    end

    test "tell @team fans out to members and skips non-members", %{conn: conn} do
      team = "team_#{System.unique_integer([:positive])}"
      member_a = unique_session()
      member_b = unique_session()
      outsider = unique_session()
      text = "for the team #{team}"

      assert :ok = Bus.join(team, conn: conn, session: member_a)
      assert :ok = Bus.join(team, conn: conn, session: member_b)

      assert :ok = Bus.tell("@" <> team, text, conn: conn, scope: "machine")

      for member <- [member_a, member_b] do
        assert {:ok, messages} = Bus.read(conn: conn, session: member, scope: "machine")

        assert Enum.any?(messages, fn m -> m.kind == "msg" and m.text == text end),
               "member #{member} should receive the team tell"
      end

      assert {:ok, outsider_messages} = Bus.read(conn: conn, session: outsider, scope: "machine")
      refute Enum.any?(outsider_messages, fn m -> m.text == text end)
    end

    # ---- watch (#1091, anchored to now per T54.9/#1097) ------------------

    test "watch with since: :all returns immediately when a message is already pending", %{
      conn: conn
    } do
      session = unique_session()
      text = "already pending #{session}"

      assert :ok = Bus.tell(session, text, conn: conn, scope: "machine")

      assert {:ok, messages} =
               Bus.watch(conn: conn, session: session, scope: "machine", timeout: 5, since: :all)

      assert Enum.any?(messages, fn m -> m.kind == "msg" and m.text == text end)
    end

    # T54.9/#1097: the bug was watch degenerating into peek -- a backlog a
    # prior peek left un-acked made every watch fire immediately.
    test "watch blocks to timeout over a peeked backlog instead of returning it", %{conn: conn} do
      session = unique_session()
      text = "backlog #{session}"
      opts = [conn: conn, session: session, scope: "machine"]

      assert :ok = Bus.tell(session, text, conn: conn, scope: "machine")
      assert {:ok, peeked} = Bus.peek(opts)
      assert Enum.any?(peeked, fn m -> m.text == text end)

      # default since: :now -- the un-acked backlog must NOT satisfy the watch
      assert {:error, :watch_timeout} = Bus.watch(opts ++ [timeout: 1])

      # ... and the backlog stays consumable by a subsequent read
      assert {:ok, read_back} = Bus.read(opts)
      assert Enum.any?(read_back, fn m -> m.text == text end)
    end

    test "watch wakes on a mid-watch post and returns ONLY that message, not the backlog", %{
      conn: conn
    } do
      session = unique_session()
      backlog_text = "old news #{session}"
      new_text = "wake up #{session}"
      parent = self()

      # a peeked (un-acked) backlog is pending on the durables
      assert :ok = Bus.tell(session, backlog_text, conn: conn, scope: "machine")
      {:ok, _peeked} = Bus.peek(conn: conn, session: session, scope: "machine")

      watcher =
        Task.async(fn ->
          # a second connection: the watcher parks a receive on ITS process
          {host, port} = parse_nats_url(System.fetch_env!("NATS_URL"))
          {:ok, watch_conn} = Gnat.start_link(%{host: host, port: port})
          send(parent, :watching)
          result = Bus.watch(conn: watch_conn, session: session, scope: "machine", timeout: 15)
          Gnat.stop(watch_conn)
          result
        end)

      assert_receive :watching, 5_000
      # let the watcher anchor + park, then wake it
      Process.sleep(300)
      assert :ok = Bus.tell(session, new_text, conn: conn, scope: "machine")

      assert {:ok, messages} = Task.await(watcher, 20_000)
      # exactly once: the wake path must not double-deliver via the stray
      # core-NATS signal copy (caught live on v1.143.0)
      assert Enum.count(messages, fn m -> m.kind == "msg" and m.text == new_text end) == 1
      # strictly-new only: the pre-anchor backlog is not delivered ...
      refute Enum.any?(messages, fn m -> m.text == backlog_text end)

      # ... and stays consumable by a subsequent read, which does NOT re-see
      # the watch-consumed message
      assert {:ok, read_back} = Bus.read(conn: conn, session: session, scope: "machine")
      assert Enum.any?(read_back, fn m -> m.text == backlog_text end)
      refute Enum.any?(read_back, fn m -> m.text == new_text end)
    end

    test "watch with a numeric since anchors precisely: pending past the seq returns immediately",
         %{conn: conn} do
      session = unique_session()
      text = "numeric anchor #{session}"

      assert :ok = Bus.tell(session, text, conn: conn, scope: "machine")

      # anchor 0 predates everything -- the pending message is strictly newer
      assert {:ok, messages} =
               Bus.watch(conn: conn, session: session, scope: "machine", timeout: 5, since: 0)

      assert Enum.any?(messages, fn m -> m.kind == "msg" and m.text == text end)
    end

    test "watch times out with {:error, :watch_timeout} when nothing arrives", %{conn: conn} do
      session = unique_session()

      assert {:error, :watch_timeout} =
               Bus.watch(conn: conn, session: session, scope: "machine", timeout: 1)
    end

    # ---- provision reconcile -------------------------------------------

    test "provision reconciles an existing stream's limits up to current config", %{conn: conn} do
      alias Gnat.Jetstream.API.Stream, as: JStream

      # provision (setup already ran it) -- assert the LIVE config matches
      # the current desired limits rather than whatever the store was born
      # with (the create-only bug pinned 1024/24h forever).
      assert {:ok, info} = JStream.info(conn, Kazi.Bus.Provision.stream_name())
      assert info.config.max_msg_size == 131_072
      assert info.config.max_age == 30 * 24 * 60 * 60 * 1_000_000_000
    end
  end

  defp unique_session, do: "bus_mvp_test_#{System.unique_integer([:positive])}"

  @doc false
  def parse_nats_url(url) do
    uri = URI.parse(url)
    {uri.host || "127.0.0.1", uri.port || 4222}
  end
end

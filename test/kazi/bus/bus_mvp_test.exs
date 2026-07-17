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
    test "post/tell/read/who/name all report {:error, :no_daemon} against a missing socket" do
      opts = [sock_path: "/tmp/kazi_bus_test_missing_#{System.unique_integer([:positive])}.sock"]

      assert {:error, :no_daemon} = Bus.post("note", "hi", opts)
      assert {:error, :no_daemon} = Bus.tell("someone", "hi", opts)
      assert {:error, :no_daemon} = Bus.read(opts)
      assert {:error, :no_daemon} = Bus.who(opts)
      assert {:error, :no_daemon} = Bus.name("nick", opts)
    end
  end

  # ===========================================================================
  # Untagged: nickname validation (client-side, before any connection)
  # ===========================================================================

  describe "name/2 nickname validation (T55.5)" do
    test "an empty nickname is rejected client-side" do
      assert {:error, {:invalid_nickname, "", _why}} = Bus.name("", conn: :unused)
    end

    test "an @-prefixed nickname is rejected (reserved for teams)" do
      assert {:error, {:invalid_nickname, "@team-ish", why}} =
               Bus.name("@team-ish", conn: :unused)

      assert why =~ "team"
    end

    test "a whitespace-containing nickname is rejected" do
      assert {:error, {:invalid_nickname, "two words", _why}} =
               Bus.name("two words", conn: :unused)
    end
  end

  # ===========================================================================
  # Untagged: stable fallback identity (T55.5, ADR-0073 decision point 3)
  # ===========================================================================

  describe "stable fallback identity (T55.5)" do
    test "session/1 with the whole name-resolution chain empty is a stable s- id, never os-<pid>" do
      with_cleared_identity_env(fn ->
        first = Bus.session([])
        second = Bus.session([])

        assert first == second
        assert String.starts_with?(first, "s-")
        refute first =~ ~r/^os-/
      end)
    end

    test "derive_fallback_id/3 is deterministic; any differing input changes the id" do
      base = Bus.derive_fallback_id("host-a", 123, "Thu Jul 16 12:00:00 2026")

      assert base == Bus.derive_fallback_id("host-a", 123, "Thu Jul 16 12:00:00 2026")
      assert base =~ ~r/^s-[0-9a-f]{12}$/

      # a different host, pid, or start time (pid reuse) must not collide
      refute base == Bus.derive_fallback_id("host-b", 123, "Thu Jul 16 12:00:00 2026")
      refute base == Bus.derive_fallback_id("host-a", 124, "Thu Jul 16 12:00:00 2026")
      refute base == Bus.derive_fallback_id("host-a", 123, "Thu Jul 16 12:00:01 2026")
    end

    # The acceptance constraint, exercised against REAL processes: two
    # separate transient `-c` shells spawned from the same stable parent (this
    # BEAM -- standing in for the harness that spawns a shell per CLI call)
    # must walk to the SAME anchor and yield the SAME id.
    test "two transient -c shells from one parent yield the same fallback id (no ghost rows)" do
      {port_1, pid_1} = spawn_transient_shell()
      {port_2, pid_2} = spawn_transient_shell()

      assert pid_1 != pid_2
      assert Bus.fallback_id_from(pid_1) == Bus.fallback_id_from(pid_2)
      assert Bus.fallback_id_from(pid_1) =~ ~r/^s-[0-9a-f]{12}$/

      Port.close(port_1)
      Port.close(port_2)
    end

    # Two genuinely different anchor processes (each its own non-shell
    # candidate) must NOT collide.
    test "two distinct non-shell anchor processes yield different fallback ids" do
      {port_1, pid_1} = spawn_sleeper()
      {port_2, pid_2} = spawn_sleeper()

      refute Bus.fallback_id_from(pid_1) == Bus.fallback_id_from(pid_2)

      Port.close(port_1)
      Port.close(port_2)
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

      # T55.5: tell resolves recipients against the roster, so the recipient
      # must have presence (any bus call establishes it).
      assert {:ok, _} = Bus.who(opts_a)

      assert {:ok, _receipt} = Bus.tell(session_a, "for A only", conn: conn, scope: "machine")

      assert {:ok, messages_a} = Bus.read(opts_a)
      assert Enum.any?(messages_a, fn m -> m.kind == "msg" and m.text == "for A only" end)

      assert {:ok, messages_b} = Bus.read(opts_b)
      refute Enum.any?(messages_b, fn m -> m.kind == "msg" and m.text == "for A only" end)
    end

    # Issue #1065: a `tell` published under a different scope than the
    # reader's used to be stored but never delivered -- silently.
    test "a cross-scope tell still reaches the named session (issue #1065)", %{conn: conn} do
      recipient = unique_session()
      assert {:ok, _} = Bus.who(conn: conn, session: recipient)

      assert {:ok, _receipt} =
               Bus.tell(recipient, "cross-scope #{recipient}", conn: conn, scope: "project")

      assert {:ok, messages} = Bus.read(conn: conn, session: recipient, scope: "machine")

      assert Enum.any?(messages, fn m ->
               m.kind == "msg" and m.text == "cross-scope #{recipient}"
             end)
    end

    test "a same-scope tell is delivered exactly once despite the second consumer (issue #1065)",
         %{conn: conn} do
      recipient = unique_session()
      text = "exactly-once #{recipient}"
      assert {:ok, _} = Bus.who(conn: conn, session: recipient)

      assert {:ok, _receipt} = Bus.tell(recipient, text, conn: conn, scope: "machine")

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

      # Bus pulls in batches of 100, so drain until dry: on a busy shared
      # scope the document can sit beyond the first pull (T55.1 lore).
      messages =
        Stream.repeatedly(fn -> Bus.read(opts) end)
        |> Enum.reduce_while([], fn
          {:ok, []}, acc -> {:halt, acc}
          {:ok, batch}, acc -> {:cont, acc ++ batch}
        end)

      assert Enum.any?(messages, fn m -> m.text == text end)
    end

    # ---- naming + addressability (T55.5, ADR-0073 d3) -------------------

    test "bus name then who shows the nickname; an unrelated post preserves it", %{conn: conn} do
      session = unique_session()
      nickname = "nick_#{System.unique_integer([:positive])}"
      opts = [conn: conn, session: session, scope: "machine"]

      assert :ok = Bus.name(nickname, opts)
      assert {:ok, sessions} = Bus.who(opts)
      assert Enum.any?(sessions, fn s -> s["session"] == session and s["name"] == nickname end)

      # the name survives an unrelated bus call's presence refresh
      assert :ok = Bus.post("note", "still named #{session}", opts)
      assert {:ok, sessions2} = Bus.who(opts)
      assert Enum.any?(sessions2, fn s -> s["session"] == session and s["name"] == nickname end)
    end

    test "tell <nickname> reaches the same consumer as tell <session-id>", %{conn: conn} do
      session = unique_session()
      nickname = "nick_#{System.unique_integer([:positive])}"
      opts = [conn: conn, session: session, scope: "machine"]

      assert :ok = Bus.name(nickname, opts)

      assert {:ok, _receipt} =
               Bus.tell(nickname, "via nickname #{session}", conn: conn, scope: "machine")

      # T55.5: tell resolves recipients against the roster -- establish
      # the recipient's presence first (any bus call does).
      assert {:ok, _} = Bus.who(conn: conn, session: session)

      # T55.5: tell resolves recipients against the roster -- establish
      # the recipient's presence first (any bus call does).
      assert {:ok, _} = Bus.who(conn: conn, session: session)

      # T55.5: tell resolves recipients against the roster -- establish
      # the recipient's presence first (any bus call does).
      assert {:ok, _} = Bus.who(conn: conn, session: session)

      # T55.5: tell resolves recipients against the roster -- establish
      # the recipient's presence first (any bus call does).
      assert {:ok, _} = Bus.who(conn: conn, session: session)

      # T55.5: tell resolves recipients against the roster -- establish
      # the recipient's presence first (any bus call does).
      assert {:ok, _} = Bus.who(conn: conn, session: session)

      assert {:ok, _receipt} =
               Bus.tell(session, "via session id #{session}", conn: conn, scope: "machine")

      assert {:ok, messages} = Bus.read(opts)
      texts = messages |> Enum.filter(&(&1.kind == "msg")) |> Enum.map(& &1.text)

      assert "via nickname #{session}" in texts
      assert "via session id #{session}" in texts
    end

    test "an unknown recipient is an error naming the live roster, never a silent send", %{
      conn: conn
    } do
      sender = unique_session()
      nickname = "roster_nick_#{System.unique_integer([:positive])}"
      assert :ok = Bus.name(nickname, conn: conn, session: sender)

      assert {:error, {:unknown_recipient, "nobody-here-t55", roster}} =
               Bus.tell("nobody-here-t55", "lost", conn: conn, session: sender)

      assert Enum.any?(roster, fn label -> label =~ nickname end)
    end

    test "re-asserting a name re-binds it to the current session", %{conn: conn} do
      old_session = unique_session()
      new_session = unique_session()
      nickname = "rebind_#{System.unique_integer([:positive])}"

      assert :ok = Bus.name(nickname, conn: conn, session: old_session)
      assert :ok = Bus.name(nickname, conn: conn, session: new_session)

      assert {:ok, sessions} = Bus.who(conn: conn, session: new_session)

      assert Enum.any?(sessions, fn s -> s["session"] == new_session and s["name"] == nickname end)

      refute Enum.any?(sessions, fn s -> s["session"] == old_session and s["name"] == nickname end)

      # the nickname now routes to the NEW session only
      assert {:ok, _receipt} =
               Bus.tell(nickname, "for the new holder", conn: conn, scope: "machine")

      assert {:ok, new_messages} = Bus.read(conn: conn, session: new_session, scope: "machine")
      assert Enum.any?(new_messages, fn m -> m.text == "for the new holder" end)

      assert {:ok, old_messages} = Bus.read(conn: conn, session: old_session, scope: "machine")
      refute Enum.any?(old_messages, fn m -> m.text == "for the new holder" end)
    end

    test "a nickname equal to a DIFFERENT live session's id is rejected", %{conn: conn} do
      other = unique_session()
      me = unique_session()
      assert {:ok, _} = Bus.who(conn: conn, session: other)

      assert {:error, {:invalid_nickname, ^other, _why}} =
               Bus.name(other, conn: conn, session: me)
    end

    test "a nameless session upserts ONE presence row across calls (stable fallback id)", %{
      conn: conn
    } do
      with_cleared_identity_env(fn ->
        fallback_id = Bus.stable_fallback_id()

        # two separate bus calls with NO session identity resolvable
        assert :ok = Bus.post("note", "fallback one", conn: conn, scope: "machine")
        assert :ok = Bus.post("note", "fallback two", conn: conn, scope: "machine")

        assert {:ok, sessions} = Bus.who(conn: conn, session: fallback_id)
        rows = Enum.filter(sessions, fn s -> String.starts_with?(s["session"], "s-") end)

        assert [%{"session" => ^fallback_id}] = rows
      end)
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

      assert {:ok, _receipt} = Bus.tell("@" <> team, text, conn: conn, scope: "machine")

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
      assert {:ok, _} = Bus.who(conn: conn, session: session)

      assert {:ok, _receipt} = Bus.tell(session, text, conn: conn, scope: "machine")

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

      # T55.5: establish the recipient's presence (tell resolves the roster).
      assert {:ok, _} = Bus.who(conn: conn, session: session)

      assert {:ok, _receipt} = Bus.tell(session, text, conn: conn, scope: "machine")
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

      # T55.5: tell resolves recipients against the roster -- establish
      # the recipient's presence first (any bus call does).
      assert {:ok, _} = Bus.who(conn: conn, session: session)

      # a peeked (un-acked) backlog is pending on the durables
      assert {:ok, _receipt} = Bus.tell(session, backlog_text, conn: conn, scope: "machine")
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
      # T55.5: establish the recipient's presence (tell resolves the roster).
      assert {:ok, _} = Bus.who(conn: conn, session: session)

      assert {:ok, _receipt} = Bus.tell(session, new_text, conn: conn, scope: "machine")

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

      # T55.5: establish the recipient's presence (tell resolves the roster).
      assert {:ok, _} = Bus.who(conn: conn, session: session)

      assert {:ok, _receipt} = Bus.tell(session, text, conn: conn, scope: "machine")

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

  # Clears every env var the session-name resolution chain reads, so the
  # stable-fallback path is what `session/1` exercises; restores them after.
  defp with_cleared_identity_env(fun) do
    vars = ["KAZI_SESSION_NAME", "CLAUDE_CODE_SESSION_ID"]
    saved = Enum.map(vars, fn var -> {var, System.get_env(var)} end)
    Enum.each(vars, &System.delete_env/1)

    try do
      fun.()
    after
      Enum.each(saved, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end
  end

  # A transient `-c` shell child of this BEAM: `sh -c 'sleep ...; :'` (the
  # trailing command defeats sh's exec-single-command optimization, so the
  # SHELL stays alive as the ps-visible process). Stands in for the throwaway
  # wrapper a harness spawns per CLI invocation.
  defp spawn_transient_shell do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "sleep 15; :"]])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  # A non-shell child process: its own anchor in the fallback walk.
  defp spawn_sleeper do
    sleep_bin = System.find_executable("sleep") || "/bin/sleep"
    port = Port.open({:spawn_executable, sleep_bin}, [:binary, args: ["15"]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  @doc false
  def parse_nats_url(url) do
    uri = URI.parse(url)
    {uri.host || "127.0.0.1", uri.port || 4222}
  end
end

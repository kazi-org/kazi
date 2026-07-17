defmodule Kazi.Bus.DaemonDigestTest do
  @moduledoc """
  T55.7 (ADR-0072 decision 5): digest assembly lives in the DAEMON. The client
  sends `read` over the control socket; the daemon pulls the consumer,
  aggregates, and enforces the bound before the bytes ever reach a client.

  Unlike `Kazi.Bus.DigestMachinePathTest` (T55.1), which passes `opts[:conn]`
  and never starts a daemon, these tests start a REAL daemon tree -- socket,
  supervised nats-server, JetStream store -- because the daemon IS the subject:
  a test that injects a connection would test the pure renderer again and prove
  nothing about where assembly happens.

  Covers the task's acceptance: a 200-message backlog returns one bounded
  digest with exact counts, rendered by the CLI without re-aggregating; the
  CLI, MCP, and hook paths produce IDENTICAL digests for the same backlog;
  `--since <cursor>` replays from a point; and with the daemon DOWN every bus
  surface still reports the clean one-line no-daemon error (ADR-0067 point 1 --
  convergence never depends on the bus).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Gnat.Jetstream.API.Stream, as: JStream
  alias Kazi.Bus
  alias Kazi.Bus.Digest
  alias Kazi.Bus.Provision
  alias Kazi.Daemon
  alias Kazi.MCP.Server
  alias Kazi.TestSupport.NatsPrereq

  @moduletag :nats_group

  # Each test boots a real daemon (a supervised nats-server) and every
  # `Bus.post` upserts presence, which shells out to `ps` for process liveness
  # -- so a 200-message backlog is 200 subprocesses. That clears the 60s
  # default comfortably on an idle machine and not at all on a busy one.
  @moduletag timeout: 300_000

  # DELIBERATELY NOT `:nats`-tagged, unlike the sibling bus suites. That tag
  # means "needs an external NATS_URL server", which CI does not provide and
  # therefore excludes -- and T55.7's acceptance is exactly the kind of thing
  # that must not rot unexercised. These tests start their OWN daemon (and its
  # supervised nats-server) and never read NATS_URL, so they run everywhere
  # `nats-server` is on PATH -- the `Kazi.Daemon.LifecycleTest` pattern, which
  # is the real precedent for a daemon-booting test. `NatsPrereq.ensure!/0`
  # turns a missing binary into one actionable line rather than an opaque
  # MatchError.
  describe "server-side assembly against a real daemon" do
    setup do
      NatsPrereq.ensure!()
      daemon = start_daemon()
      {:ok, conn} = Gnat.start_link(%{host: "127.0.0.1", port: daemon.port})
      on_exit(fn -> if Process.alive?(conn), do: Gnat.stop(conn) end)
      :ok = Provision.provision(conn)

      # A unique scope + session per test: durable consumers are named after
      # the session, so sharing either would let one test drain another's
      # backlog (and replay stream history onto a fresh durable).
      id = System.unique_integer([:positive])

      %{
        conn: conn,
        sock_path: daemon.sock_path,
        scope: "t55_7_scope_#{id}",
        session: "t55_7_session_#{id}"
      }
    end

    test "a 200-message backlog returns ONE bounded digest with exact counts", ctx do
      post_backlog(ctx, 200)
      await_stream_messages(ctx.conn, 200)

      assert {:ok, %{"digest" => digest}} = read_digest(ctx)

      # The daemon walked the WHOLE backlog: one read, all 200 counted, even
      # though Kazi.Bus pulls in batches of 100 (L-0040). A client-side read
      # would have stopped at the first batch.
      assert digest["total"] == 200
      assert length(digest["lines"]) <= Digest.max_lines()
      assert Enum.sum(Enum.map(digest["lines"], & &1["count"])) == 200
    end

    test "the CLI renders the daemon's digest without re-aggregating", ctx do
      post_backlog(ctx, 12)

      assert {:ok, %{"digest" => digest} = reply} = read_digest(ctx)

      # The CLI's TTY view is a pure function of what the daemon assembled --
      # same line count, no second pass over any message.
      tty = Digest.to_tty_lines(digest)
      assert length(tty) == length(digest["lines"])

      payload = Kazi.CLI.bus_read_payload(reply)
      assert payload["ok"] == true
      assert payload["schema_version"] == Kazi.CLI.Schema.schema_version()
      assert payload["digest"] == digest
      refute Map.has_key?(payload, "messages")
    end

    test "CLI, MCP, and hook paths produce IDENTICAL digests for the same backlog", ctx do
      post_backlog(ctx, 9)
      :ok = Bus.post("fact", "current state", conn: ctx.conn, scope: ctx.scope, topic: "build")

      # `peek` (non-destructive) is the only way to ask three surfaces about
      # the SAME backlog: a `read` acks, so the second caller would see an
      # empty bus and the comparison would be vacuous.
      cli = cli_peek_digest(ctx)
      mcp = mcp_peek_digest(ctx)
      hook = hook_peek_digest(ctx)

      assert cli == mcp
      assert mcp == hook
      assert cli["total"] == 10
      assert length(cli["lines"]) <= Digest.max_lines()
    end

    test "--since <cursor> replays from a point", ctx do
      :ok = Bus.post("fact", "before the cursor", conn: ctx.conn, scope: ctx.scope, topic: "ci")

      # The cursor is the id of a message that has ACTUALLY landed. Reading it
      # from stream info instead would race: `Bus.post` does not wait for
      # JetStream to persist, so `last_seq` can still be behind the message the
      # cursor is meant to anchor -- a cursor one short then replays it too.
      cursor = await_id(ctx, "before the cursor")

      :ok = Bus.post("fact", "after the cursor", conn: ctx.conn, scope: ctx.scope, topic: "ci")
      await_id(ctx, "after the cursor")

      assert {:ok, %{"digest" => digest}} = read_digest(ctx, since: cursor)
      assert digest["total"] == 1
      assert [line] = digest["lines"]
      assert line["last"] == "after the cursor"

      # And the message BEFORE the cursor was not eaten -- a `--since` probe
      # NAKs the backlog back, so a plain read still sees it. This is what
      # makes it a debugging escape rather than a destructive filter.
      assert {:ok, %{"digest" => plain}} = read_digest(ctx)
      assert plain["total"] == 1
      assert [plain_line] = plain["lines"]
      assert plain_line["last"] == "before the cursor"
    end

    test "--since past the newest sequence is an empty replay, not an error", ctx do
      :ok = Bus.post("fact", "the only message", conn: ctx.conn, scope: ctx.scope, topic: "ci")
      cursor = await_id(ctx, "the only message")

      assert {:ok, %{"digest" => digest}} = read_digest(ctx, since: cursor + 100)
      assert digest["total"] == 0
      assert digest["lines"] == []
    end

    test "full: true escapes the bound and returns messages the client can use", ctx do
      :ok = Bus.post("fact", "unabridged", conn: ctx.conn, scope: ctx.scope, topic: "ci")

      assert {:ok, %{"messages" => messages}} = read_digest(ctx, full: true)

      # The daemon's messages cross the socket as JSON; the client re-atomizes
      # them, so a caller reaches `.text`/`.id` exactly as with `Bus.read/1`.
      assert [message] = messages
      assert message.text == "unabridged"
      assert message.kind == "fact"
      assert is_integer(message.id)
    end

    test "the daemon aggregates last-value facts per topic (ADR-0072 d5)", ctx do
      opts = [conn: ctx.conn, scope: ctx.scope, topic: "build"]
      :ok = Bus.post("fact", "build red", opts)
      :ok = Bus.post("fact", "build flaky", opts)
      :ok = Bus.post("fact", "build green", opts)

      assert {:ok, %{"digest" => digest}} = read_digest(ctx)

      # Three facts on one topic are ONE line carrying what is true NOW --
      # a reader needs the current value, not that three things were said.
      assert [line] = digest["lines"]
      assert line["type"] == "count"
      assert line["count"] == 3
      assert line["last"] == "build green"
      assert Digest.to_tty_lines(digest) == ["3 fact/build -- build green"]
    end

    test "the daemon enforces verbatim-only-for-directed-or-interrupt", ctx do
      opts = [conn: ctx.conn, scope: ctx.scope, topic: "ci"]
      :ok = Bus.post("note", "urgent", opts ++ [sev: "interrupt"])
      :ok = Bus.post("note", "routine", opts)

      assert {:ok, %{"digest" => digest}} = read_digest(ctx)

      assert [verbatim] = Enum.filter(digest["lines"], &(&1["type"] == "verbatim"))
      assert verbatim["text"] == "urgent"

      # The routine note never renders its body -- it is a count line.
      assert [count] = Enum.filter(digest["lines"], &(&1["type"] == "count"))
      assert count["count"] == 1
      refute Map.has_key?(count, "last")
    end

    test "an oversized body is a stub before it ever reaches the client", ctx do
      body = String.duplicate("x", 2 * Digest.render_threshold_bytes())
      opts = [conn: ctx.conn, scope: ctx.scope, topic: "doc"]
      :ok = Bus.post("note", body, opts ++ [sev: "interrupt"])

      assert {:ok, %{"digest" => digest}} = read_digest(ctx)

      # The bound is enforced SERVER-side: the big body is not in the reply at
      # all, which is the whole point -- a client-side bound would have paid
      # for the bytes to arrive before dropping them.
      assert [stub] = digest["lines"]
      assert stub["type"] == "stub"
      assert stub["bytes"] == byte_size(body)
      assert is_integer(stub["id"])
      refute Map.has_key?(stub, "text")
    end

    # Moved here from Kazi.Bus.DigestMachinePathTest (T55.1), which injected
    # `conn:` and never started a daemon: T55.7 routes the MCP read through the
    # control socket, so this contract can only be tested against a real one.
    test "kazi_bus_read (MCP) returns the digest by default; full: true every message unabridged",
         ctx do
      body = "mcp-doc " <> String.duplicate("y", 60 * 1024)
      :ok = Bus.post("note", body, conn: ctx.conn, scope: ctx.scope, topic: "doc")
      :ok = Bus.post("fact", "small mcp fact", conn: ctx.conn, scope: ctx.scope, topic: "ci")

      digest_result = mcp_read(ctx, %{"peek" => true})

      assert digest_result["ok"] == true
      assert digest_result["schema_version"] == Kazi.CLI.Schema.schema_version()
      refute Map.has_key?(digest_result, "messages")

      %{"total" => 2, "lines" => lines} = digest_result["digest"]
      assert length(lines) <= Digest.max_lines()
      assert [stub] = Enum.filter(lines, &(&1["type"] == "stub"))
      refute Map.has_key?(stub, "text")

      # full: true is the documented escape -- every message unabridged.
      full_result = mcp_read(ctx, %{"peek" => true, "full" => true})

      assert full_result["schema_version"] == Kazi.CLI.Schema.schema_version()
      refute Map.has_key?(full_result, "digest")

      messages = full_result["messages"]
      assert Enum.any?(messages, fn m -> m.text == body end)
      assert Enum.any?(messages, fn m -> m.text == "small mcp fact" end)
      assert Enum.all?(messages, fn m -> is_integer(m.id) end)
    end

    # The landmine this task found: `packet: :line` truncates an over-long
    # line SILENTLY -- `recv` says `:ok` and hands back a short binary. A
    # digest of 40 verbatim lines at the ~1 KiB render threshold is tens of KB
    # and was corrupted by the 9,216-byte default. If this regresses, a read
    # comes back as a decode failure rather than a digest.
    test "a digest at the render bound survives the control socket intact", ctx do
      # 30 directed messages, each just under the threshold: all verbatim, so
      # the reply is as large as a bounded digest can legitimately get.
      assert {:ok, _who} = Bus.who(conn: ctx.conn, session: ctx.session)
      body = String.duplicate("z", Digest.render_threshold_bytes() - 1)

      for _i <- 1..30 do
        assert {:ok, _receipt} = Bus.tell(ctx.session, body, conn: ctx.conn, scope: ctx.scope)
      end

      await_stream_messages(ctx.conn, 30)

      assert {:ok, %{"digest" => digest}} = read_digest(ctx)

      verbatim = Enum.filter(digest["lines"], &(&1["type"] == "verbatim"))
      assert length(verbatim) == 30
      assert Enum.all?(verbatim, fn line -> line["text"] == body end)

      # The reply really was larger than the default buffer -- i.e. this test
      # would have caught the bug.
      assert byte_size(Jason.encode!(digest)) > 9_216
    end

    test "the daemon drains the caller's OWN session, never its own identity", ctx do
      # A directed message is addressed to the client's session id. The daemon
      # has no KAZI_SESSION_NAME and its cwd is not the caller's repo, so if it
      # resolved identity itself this message would go undelivered.
      assert {:ok, _who} = Bus.who(conn: ctx.conn, session: ctx.session)

      assert {:ok, _receipt} =
               Bus.tell(ctx.session, "directed at the client", conn: ctx.conn, scope: ctx.scope)

      assert {:ok, %{"digest" => digest}} = read_digest(ctx)

      assert Enum.any?(digest["lines"], fn line ->
               line["type"] == "verbatim" and line["text"] == "directed at the client"
             end)
    end
  end

  # ADR-0067 point 1: with the daemon down, every bus surface reports a clean
  # one-line error and no-ops. No nats, no daemon, no tag -- if this needed a
  # server it would not be testing the down path.
  describe "with the daemon DOWN (ADR-0067 point 1)" do
    setup do
      %{sock_path: "/tmp/kazi_t55_7_absent_#{System.unique_integer([:positive])}.sock"}
    end

    test "Kazi.Bus.read_digest/1 returns :no_daemon, never a raise", ctx do
      assert {:error, :no_daemon} = Bus.read_digest(sock_path: ctx.sock_path, session: "s")
      assert {:error, :no_daemon} = Bus.read_digest(sock_path: ctx.sock_path, peek: true)
      assert {:error, :no_daemon} = Bus.read_digest(sock_path: ctx.sock_path, full: true)
      assert {:error, :no_daemon} = Bus.read_digest(sock_path: ctx.sock_path, since: 1)
    end

    test "a STALE socket file is not mistaken for a live daemon", ctx do
      File.write!(ctx.sock_path, "")
      on_exit(fn -> File.rm(ctx.sock_path) end)

      assert {:error, :no_daemon} = Bus.read_digest(sock_path: ctx.sock_path)
    end

    # The CLI has no --sock-path seam, so it is pinned away from a developer's
    # (or CI's) real daemon the way the rest of the bus CLI suite does it:
    # KAZI_STATE_DIR moves the default socket path into an empty tmp dir.
    test "`bus read` prints ONE line to stderr and exits 1" do
      in_empty_state_dir(fn ->
        stderr = capture_io(:stderr, fn -> assert Kazi.CLI.run(["bus", "read"], []) == 1 end)

        assert stderr =~ "no daemon running"
        assert length(String.split(String.trim(stderr), "\n")) == 1
      end)
    end

    test "`bus peek`, `--full`, and `--since` degrade the same way `bus read` does" do
      in_empty_state_dir(fn ->
        for argv <- [
              ["bus", "peek"],
              ["bus", "read", "--full"],
              ["bus", "read", "--since", "1"],
              ["bus", "peek", "--full"]
            ] do
          stderr = capture_io(:stderr, fn -> assert Kazi.CLI.run(argv, []) == 1 end)
          assert stderr =~ "no daemon running", "#{Enum.join(argv, " ")} did not degrade cleanly"
        end
      end)
    end

    # The machine surface degrades on its OWN channel: one JSON object on
    # stdout, exit 1. An agent parsing stdout gets a structured refusal, not a
    # half-written digest.
    test "`bus read --json` degrades to one JSON error object on stdout" do
      in_empty_state_dir(fn ->
        stdout = capture_io(fn -> assert Kazi.CLI.run(["bus", "read", "--json"], []) == 1 end)

        assert {:ok, decoded} = Jason.decode(String.trim(stdout))
        assert decoded["error"] =~ "no daemon running"
        refute Map.has_key?(decoded, "digest")
      end)
    end

    test "the MCP tool reports the same no-daemon error, never isError-free silence", ctx do
      assert %{"result" => %{"isError" => true, "structuredContent" => content}} =
               Server.handle_request(
                 request("kazi_bus_read", %{}),
                 sock_path: ctx.sock_path
               )

      assert content["reason"] == "no_daemon"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp in_empty_state_dir(fun) do
    state_dir = Path.join(System.tmp_dir!(), "kazi_t55_7_#{System.unique_integer([:positive])}")
    previous = System.get_env("KAZI_STATE_DIR")
    System.put_env("KAZI_STATE_DIR", state_dir)

    try do
      fun.()
    after
      if previous,
        do: System.put_env("KAZI_STATE_DIR", previous),
        else: System.delete_env("KAZI_STATE_DIR")

      File.rm_rf(state_dir)
    end
  end

  # Short, /tmp-rooted socket paths: AF_UNIX caps sun_path at ~104 bytes on
  # macOS and System.tmp_dir!() (/var/folders/...) can blow that budget
  # (L-0039).
  defp start_daemon do
    id = System.unique_integer([:positive])
    sock_path = "/tmp/kazi_t55_7_#{id}.sock"
    port = 21_000 + rem(id, 19_000)

    opts = [
      sock_path: sock_path,
      pid_path: "/tmp/kazi_t55_7_#{id}.pid",
      name: :"t55_7_sup_#{id}",
      listener_name: :"t55_7_listener_#{id}",
      nats_name: :"t55_7_nats_#{id}",
      sweep_name: :"t55_7_sweep_#{id}",
      store_dir: "/tmp/kazi_t55_7_js_#{id}",
      port: port
    ]

    # Registered under ExUnit's supervisor, not linked to the test process:
    # a daemon started in the test process tears itself down on that process's
    # exit, racing on_exit (the daemon_lifecycle_test pattern).
    start_supervised!(%{id: :"t55_7_daemon_#{id}", start: {Daemon, :start, [opts]}})
    on_exit(fn -> File.rm_rf("/tmp/kazi_t55_7_js_#{id}") end)

    %{sock_path: sock_path, port: port}
  end

  defp post_backlog(ctx, count) do
    for i <- 1..count do
      kind = Enum.at(~w(fact note intent), rem(i, 3))
      :ok = Bus.post(kind, "backlog #{i}", conn: ctx.conn, scope: ctx.scope, topic: "load")
    end
  end

  defp read_digest(ctx, extra \\ []) do
    Bus.read_digest([sock_path: ctx.sock_path, session: ctx.session, scope: ctx.scope] ++ extra)
  end

  # The three surfaces, each asking the daemon for the same non-destructive
  # peek. Whatever they return must be byte-identical -- that is the property
  # T55.7 exists to guarantee.
  defp cli_peek_digest(ctx) do
    assert {:ok, %{"digest" => digest}} = read_digest(ctx, peek: true)
    digest
  end

  defp mcp_peek_digest(ctx), do: mcp_read(ctx, %{"peek" => true})["digest"]

  defp mcp_read(ctx, args) do
    assert %{"result" => %{"structuredContent" => result}} =
             Server.handle_request(
               request("kazi_bus_read", Map.put(args, "scope", ctx.scope)),
               sock_path: ctx.sock_path,
               session: ctx.session
             )

    result
  end

  # The ADR-0071 hook's source. `kazi bus hook <event>` is a silent skeleton
  # until T55.9 fills in the payload, so this pins what T55.9 will inject:
  # the hook reads through the SAME entry point, which is what stops it from
  # re-implementing the bound a third time.
  defp hook_peek_digest(ctx) do
    assert {:ok, %{"digest" => digest}} =
             Bus.read_digest(
               sock_path: ctx.sock_path,
               session: ctx.session,
               scope: ctx.scope,
               peek: true
             )

    digest
  end

  # The id of a posted message, once it has actually landed. A `full` peek is
  # non-destructive (it NAKs everything it sees), so polling with it does not
  # consume the very backlog the test is about to assert on.
  defp await_id(ctx, text, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000
    {:ok, %{"messages" => messages}} = read_digest(ctx, peek: true, full: true)

    case Enum.find(messages, fn m -> m.text == text end) do
      %{id: id} when is_integer(id) ->
        id

      _not_yet ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("#{inspect(text)} never landed on the bus within 5s")
        end

        Process.sleep(50)
        await_id(ctx, text, deadline)
    end
  end

  # Waits until the stream has persisted `expected` messages. `Bus.post`
  # publishes without waiting, so a read issued too early can drain a
  # half-written backlog and under-count through no fault of the daemon.
  defp await_stream_messages(conn, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000
    {:ok, %{state: %{messages: count}}} = JStream.info(conn, Provision.stream_name())

    cond do
      count >= expected ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("only #{count}/#{expected} messages persisted within 15s")

      true ->
        Process.sleep(50)
        await_stream_messages(conn, expected, deadline)
    end
  end

  defp request(tool, args) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => tool, "arguments" => args}
    }
  end
end

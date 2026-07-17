defmodule Kazi.Bus.DeliveryVisibilityTest do
  @moduledoc """
  T55.12: delivery visibility for `bus tell`.

  `tell` used to answer `:ok`, which meant QUEUED, not seen -- a supervisor
  could not tell delivered-and-ignored from parked-in-a-queue-nobody-drains
  from lost-because-the-session-was-replaced. These tests pin the three
  signals that close that gap: the receipt's id, `status/2`'s ack-state
  verdict, and `who`'s per-session inbox depth.

  UNTAGGED tests (always run, no NATS needed): the no-daemon error path.

  `:nats`-TAGGED tests mirror `Kazi.Bus.MvpTest` (excluded by default; run
  with `NATS_URL` set): the real ack-state semantics against a live
  JetStream server via `opts[:conn]`.
  """
  use ExUnit.Case, async: false

  alias Gnat.Jetstream.API.KV
  alias Kazi.Bus
  alias Kazi.Bus.Liveness
  alias Kazi.Bus.Provision

  # ===========================================================================
  # Untagged
  # ===========================================================================

  describe "no daemon" do
    test "status reports {:error, :no_daemon} against a missing socket" do
      opts = [
        sock_path: "/tmp/kazi_bus_status_missing_#{System.unique_integer([:positive])}.sock"
      ]

      assert {:error, :no_daemon} = Bus.status(1, opts)
    end
  end

  # ===========================================================================
  # :nats-tagged (excluded by default; NATS_URL required)
  # ===========================================================================

  describe "tell receipts against a real NATS JetStream server" do
    @describetag :nats

    setup :nats_conn

    test "tell returns a receipt carrying the message's stream-seq id", %{conn: conn} do
      recipient = live_session(conn)

      assert {:ok, receipt} =
               Bus.tell(recipient, "hello", conn: conn, session: unique_session())

      assert is_integer(receipt.id)
      assert receipt.id > 0
      assert receipt.recipient == recipient
    end

    test "the receipt's id is the id the recipient's read reports for that message", %{conn: conn} do
      recipient = live_session(conn)

      assert {:ok, receipt} =
               Bus.tell(recipient, "trace me", conn: conn, session: unique_session())

      assert {:ok, messages} = drain_all(conn, recipient)
      assert msg = Enum.find(messages, &(&1.text == "trace me"))
      assert msg.id == receipt.id
    end

    test "successive tells get strictly increasing ids", %{conn: conn} do
      recipient = live_session(conn)
      sender = unique_session()

      assert {:ok, first} = Bus.tell(recipient, "one", conn: conn, session: sender)
      assert {:ok, second} = Bus.tell(recipient, "two", conn: conn, session: sender)

      assert second.id > first.id
    end
  end

  describe "status/2 against a real NATS JetStream server" do
    @describetag :nats

    setup :nats_conn

    test "flips pending -> consumed after the recipient's read", %{conn: conn} do
      recipient = live_session(conn)

      assert {:ok, receipt} =
               Bus.tell(recipient, "read me", conn: conn, session: unique_session())

      assert {:ok, before} = Bus.status(receipt.id, conn: conn, session: unique_session())
      assert before["state"] == "pending"
      assert before["recipient"] == recipient

      assert {:ok, _messages} = drain_all(conn, recipient)

      assert {:ok, after_read} = Bus.status(receipt.id, conn: conn, session: unique_session())
      assert after_read["state"] == "consumed"
    end

    test "a peek does NOT flip status to consumed -- peek NAKs, it never consumes", %{conn: conn} do
      recipient = live_session(conn)

      assert {:ok, receipt} =
               Bus.tell(recipient, "peek me", conn: conn, session: unique_session())

      assert {:ok, _messages} = Bus.peek(conn: conn, session: recipient, scope: "machine")

      assert {:ok, status} = Bus.status(receipt.id, conn: conn, session: unique_session())
      assert status["state"] == "pending"
    end

    test "reports per-recipient state, one entry for a single-session tell", %{conn: conn} do
      recipient = live_session(conn)

      assert {:ok, receipt} =
               Bus.tell(recipient, "detail", conn: conn, session: unique_session())

      assert {:ok, status} = Bus.status(receipt.id, conn: conn, session: unique_session())
      assert [%{"session" => ^recipient, "state" => "pending"}] = status["recipients"]
    end

    test "an unknown id is a one-line error, never a fabricated verdict", %{conn: conn} do
      assert {:error, {:unknown_message, 999_999}} =
               Bus.status(999_999, conn: conn, session: unique_session())
    end

    test "a broadcast post is not a directed message -- status says so instead of guessing", %{
      conn: conn
    } do
      sender = unique_session()
      assert :ok = Bus.post("fact", "broadcast", conn: conn, session: sender, scope: "machine")

      assert {:ok, messages} = Bus.read(conn: conn, session: sender, scope: "machine")
      assert fact = Enum.find(messages, &(&1.text == "broadcast"))

      assert {:error, {:not_directed, _id, "fact"}} =
               Bus.status(fact.id, conn: conn, session: unique_session())
    end

    test "status consumes nothing -- a later read still delivers the message", %{conn: conn} do
      recipient = live_session(conn)

      assert {:ok, receipt} =
               Bus.tell(recipient, "still here", conn: conn, session: unique_session())

      assert {:ok, _status} = Bus.status(receipt.id, conn: conn, session: unique_session())

      assert {:ok, messages} = drain_all(conn, recipient)
      assert Enum.find(messages, &(&1.text == "still here"))
    end
  end

  describe "status/2 for a team tell" do
    @describetag :nats

    setup :nats_conn

    test "reports per-member state and only reads consumed once every member acked", %{conn: conn} do
      team = "t55-12-#{System.unique_integer([:positive])}"
      member_a = unique_session()
      member_b = unique_session()

      :ok = Bus.join(team, conn: conn, session: member_a)
      :ok = Bus.join(team, conn: conn, session: member_b)

      assert {:ok, receipt} =
               Bus.tell("@" <> team, "all hands", conn: conn, session: unique_session())

      assert {:ok, status} = Bus.status(receipt.id, conn: conn, session: unique_session())
      assert status["recipient"] == "@" <> team
      assert status["state"] == "pending"
      assert length(status["recipients"]) == 2

      # One member reads: the aggregate stays pending while the other has not.
      assert {:ok, _} = Bus.read(conn: conn, session: member_a, scope: "machine")

      assert {:ok, partial} = Bus.status(receipt.id, conn: conn, session: unique_session())
      assert partial["state"] == "pending"
      assert %{"state" => "consumed"} = find_recipient(partial, member_a)
      assert %{"state" => "pending"} = find_recipient(partial, member_b)

      # Both read: the aggregate flips.
      assert {:ok, _} = Bus.read(conn: conn, session: member_b, scope: "machine")

      assert {:ok, full} = Bus.status(receipt.id, conn: conn, session: unique_session())
      assert full["state"] == "consumed"
    end
  end

  describe "who inbox depth against a real NATS JetStream server" do
    @describetag :nats

    setup :nats_conn

    test "shows depth N after N un-read tells, and 0 once the recipient reads", %{conn: conn} do
      recipient = live_session(conn)
      sender = unique_session()

      for n <- 1..3 do
        assert {:ok, _} = Bus.tell(recipient, "queued #{n}", conn: conn, session: sender)
      end

      assert {:ok, entries} = Bus.who(conn: conn, session: unique_session(), all: true)
      assert entry = Enum.find(entries, &(&1["session"] == recipient))
      assert entry["inbox"] == 3

      assert {:ok, _messages} = drain_all(conn, recipient)

      assert {:ok, drained} = Bus.who(conn: conn, session: unique_session(), all: true)
      assert entry = Enum.find(drained, &(&1["session"] == recipient))
      assert entry["inbox"] == 0
    end

    test "a session nobody has told carries an inbox depth of 0, never nil", %{conn: conn} do
      session = live_session(conn)

      assert {:ok, entries} = Bus.who(conn: conn, session: unique_session(), all: true)
      assert entry = Enum.find(entries, &(&1["session"] == session))
      assert entry["inbox"] == 0
    end

    test "a team tell counts toward every member's inbox depth", %{conn: conn} do
      team = "t55-12-depth-#{System.unique_integer([:positive])}"
      member = unique_session()
      :ok = Bus.join(team, conn: conn, session: member)

      assert {:ok, _} =
               Bus.tell("@" <> team, "for the team", conn: conn, session: unique_session())

      assert {:ok, entries} = Bus.who(conn: conn, session: unique_session(), all: true)
      assert entry = Enum.find(entries, &(&1["session"] == member))
      assert entry["inbox"] == 1
    end
  end

  describe "tell resolution and liveness warnings" do
    @describetag :nats

    setup :nats_conn

    test "telling an unknown session errors naming the live roster", %{conn: conn} do
      known = live_session(conn)

      assert {:error, {:unknown_recipient, "nobody-t5512", roster}} =
               Bus.tell("nobody-t5512", "lost", conn: conn, session: unique_session())

      assert Enum.any?(roster, &String.contains?(&1, known))
    end

    test "a dead-reaping recipient WARNS but still queues -- the operator may know better", %{
      conn: conn
    } do
      recipient = unique_session()

      put_row(conn, recipient, ts_seconds_ago(1),
        pid: dead_os_pid(),
        started_at: "whenever it was"
      )

      assert {:ok, receipt} =
               Bus.tell(recipient, "into the void?", conn: conn, session: unique_session())

      assert receipt.liveness == "dead-reaping"
      assert is_integer(receipt.id)

      # Still queued: the message is really in the stream, addressable.
      assert {:ok, status} = Bus.status(receipt.id, conn: conn, session: unique_session())
      assert status["state"] == "pending"
    end

    test "a live recipient carries no warning-worthy liveness", %{conn: conn} do
      recipient = live_session(conn)

      assert {:ok, receipt} =
               Bus.tell(recipient, "hi", conn: conn, session: unique_session())

      assert receipt.liveness == "active"
    end

    test "a recipient with no presence row but a durable inbox still queues", %{conn: conn} do
      # A session that read once (so it owns a durable inbox cursor) and whose
      # presence row then aged out entirely: its queue is still real and it may
      # come back to drain it, so the tell must land rather than error.
      orphan = unique_session()
      assert {:ok, _} = Bus.read(conn: conn, session: orphan, scope: "machine")
      delete_row(conn, orphan)

      assert {:ok, receipt} =
               Bus.tell(orphan, "you have mail", conn: conn, session: unique_session())

      assert receipt.liveness == "no-presence"
      assert is_integer(receipt.id)

      assert {:ok, messages} = drain_all(conn, orphan)
      assert Enum.find(messages, &(&1.text == "you have mail"))
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp nats_conn(_context) do
    {host, port} = parse_nats_url(System.fetch_env!("NATS_URL"))
    {:ok, conn} = Gnat.start_link(%{host: host, port: port})
    on_exit(fn -> if Process.alive?(conn), do: Gnat.stop(conn) end)
    :ok = Provision.provision(conn)
    %{conn: conn}
  end

  # A session with a fresh, live presence row -- `who`/`tell` resolve it as
  # `active`. Any bus call upserts presence for the calling session.
  defp live_session(conn) do
    session = unique_session()
    {:ok, _} = Bus.who(conn: conn, session: session)
    session
  end

  # L-0040: Bus pulls in batches of 100 and the shared test scope is busy, so a
  # single `read` does not necessarily surface a given message -- drain until
  # empty before asserting a round-trip.
  defp drain_all(conn, session), do: drain_all(conn, session, [])

  defp drain_all(conn, session, acc) do
    case Bus.read(conn: conn, session: session, scope: "machine") do
      {:ok, []} -> {:ok, acc}
      {:ok, messages} -> drain_all(conn, session, acc ++ messages)
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_recipient(status, session),
    do: Enum.find(status["recipients"], &(&1["session"] == session))

  defp unique_session, do: "t5512-#{System.unique_integer([:positive])}"

  defp own_os_pid, do: :os.getpid() |> to_string() |> String.to_integer()

  # A REAL pid that verifiably no longer exists: spawn a short-lived OS
  # process, wait for it to exit, and confirm ps no longer sees it.
  defp dead_os_pid do
    bin = System.find_executable("true") || "/usr/bin/true"
    port = Port.open({:spawn_executable, bin}, [:binary, :exit_status])
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      5_000 -> flunk("scratch process did not exit")
    end

    wait_until_gone(os_pid, 50)
    os_pid
  end

  defp wait_until_gone(os_pid, 0), do: flunk("scratch pid #{os_pid} never disappeared")

  defp wait_until_gone(os_pid, tries) do
    if Liveness.proc_started_at(os_pid) == nil do
      :ok
    else
      Process.sleep(20)
      wait_until_gone(os_pid, tries - 1)
    end
  end

  defp ts_seconds_ago(seconds) do
    DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()
  end

  defp put_row(conn, session, ts, overrides \\ []) do
    pid = Keyword.get(overrides, :pid, own_os_pid())

    entry =
      %{
        "session" => session,
        "machine" => Keyword.get(overrides, :machine, hostname()),
        "pid" => pid,
        "started_at" => Keyword.get(overrides, :started_at, Liveness.proc_started_at(pid)),
        "liveness" => "active",
        "cwd" => Keyword.get(overrides, :cwd, File.cwd!()),
        "ts" => ts
      }

    :ok = KV.put_value(conn, Provision.sessions_bucket(), sanitize(session), Jason.encode!(entry))
  end

  defp delete_row(conn, session),
    do: :ok = KV.delete_key(conn, Provision.sessions_bucket(), sanitize(session))

  defp sanitize(str), do: String.replace(str, ~r/[^a-zA-Z0-9_-]/, "_")

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp parse_nats_url(url) do
    uri = URI.parse(url)
    {uri.host || "127.0.0.1", uri.port || 4222}
  end
end

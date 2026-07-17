defmodule Kazi.Bus.PresenceLivenessTest do
  @moduledoc """
  T55.11: presence tells idle from dead.

  UNTAGGED tests (always run, no NATS needed): `Kazi.Bus.Liveness`'s
  pid + start-time identity -- alive, dead, pid-reuse, and inconclusive
  verdicts against real local OS processes.

  `:nats`-TAGGED tests mirror `Kazi.Bus.MvpTest` (excluded by default; run
  with `NATS_URL` set): `who`'s liveness column, the never-hide-a-live-pid
  freshness rule, and the `--project`/`--machine` filters, against a real
  JetStream server via `opts[:conn]`.
  """
  use ExUnit.Case, async: false

  alias Gnat.Jetstream.API.KV
  alias Kazi.Bus
  alias Kazi.Bus.Liveness
  alias Kazi.Bus.Provision

  # ===========================================================================
  # Untagged: Liveness verdicts
  # ===========================================================================

  describe "Liveness.proc_started_at/1" do
    test "returns an opaque, non-empty start time for a live process (our own)" do
      started = Liveness.proc_started_at(own_os_pid())

      assert is_binary(started)
      assert started != ""
    end

    test "returns nil for a pid that no longer exists" do
      assert Liveness.proc_started_at(dead_os_pid()) == nil
    end
  end

  describe "Liveness.verdict/1" do
    test "alive: recorded pid exists and start time matches" do
      pid = own_os_pid()
      entry = %{"pid" => pid, "started_at" => Liveness.proc_started_at(pid)}

      assert Liveness.verdict(entry) == :alive
    end

    test "dead: recorded pid is gone" do
      entry = %{"pid" => dead_os_pid(), "started_at" => "whenever"}

      assert Liveness.verdict(entry) == :dead
    end

    test "dead: pid reuse -- same pid, DIFFERENT start time is a different process" do
      entry = %{"pid" => own_os_pid(), "started_at" => "Thu Jan  1 00:00:00 1970"}

      assert Liveness.verdict(entry) == :dead
    end

    test "unknown: a live pid with no recorded start time is inconclusive (pre-T55.11 row)" do
      assert Liveness.verdict(%{"pid" => own_os_pid()}) == :unknown
    end

    test "unknown: no pid recorded at all" do
      assert Liveness.verdict(%{"session" => "x"}) == :unknown
    end
  end

  # ===========================================================================
  # :nats-tagged (excluded by default; NATS_URL required)
  # ===========================================================================

  describe "who liveness against a real NATS JetStream server" do
    @describetag :nats

    setup do
      {host, port} = parse_nats_url(System.fetch_env!("NATS_URL"))
      {:ok, conn} = Gnat.start_link(%{host: host, port: port})
      on_exit(fn -> if Process.alive?(conn), do: Gnat.stop(conn) end)
      :ok = Provision.provision(conn)
      %{conn: conn}
    end

    test "presence upserts record pid AND process start time, liveness active", %{conn: conn} do
      session = unique_session()
      assert {:ok, entries} = Bus.who(conn: conn, session: session)

      assert own = Enum.find(entries, &(&1["session"] == session))
      assert own["pid"] == own_os_pid()
      assert own["started_at"] == Liveness.proc_started_at(own_os_pid())
      assert own["liveness"] == "active"
      assert is_integer(own["seen_s"])
    end

    test "a TTL-stale row with a live pid renders idle -- never hidden, never dead", %{
      conn: conn
    } do
      session = unique_session()
      put_row(conn, session, ts_seconds_ago(Bus.session_ttl_s() + 100))

      assert {:ok, entries} = Bus.who(conn: conn, session: unique_session())

      assert entry = Enum.find(entries, &(&1["session"] == session))
      assert entry["liveness"] == "idle"
      refute entry["liveness"] == "dead-reaping"
    end

    test "a fresh local row with a DEAD pid renders dead-reaping", %{conn: conn} do
      session = unique_session()

      put_row(conn, session, ts_seconds_ago(1),
        pid: dead_os_pid(),
        started_at: "whenever it was"
      )

      assert {:ok, entries} = Bus.who(conn: conn, session: unique_session())

      assert entry = Enum.find(entries, &(&1["session"] == session))
      assert entry["liveness"] == "dead-reaping"
    end

    test "a TTL-stale DEAD row stays hidden by default; --all shows it", %{conn: conn} do
      session = unique_session()

      put_row(conn, session, ts_seconds_ago(Bus.session_ttl_s() + 100),
        pid: dead_os_pid(),
        started_at: "long ago"
      )

      caller = unique_session()
      assert {:ok, default_entries} = Bus.who(conn: conn, session: caller)
      refute Enum.find(default_entries, &(&1["session"] == session))

      assert {:ok, all_entries} = Bus.who(conn: conn, session: caller, all: true)
      assert entry = Enum.find(all_entries, &(&1["session"] == session))
      assert entry["liveness"] == "dead-reaping"
    end

    test "who --machine filters to that host's rows only", %{conn: conn} do
      a = unique_session()
      b = unique_session()
      put_row(conn, a, ts_seconds_ago(1), machine: "fleet-host-a")
      put_row(conn, b, ts_seconds_ago(1), machine: "fleet-host-b")

      assert {:ok, entries} =
               Bus.who(conn: conn, session: unique_session(), who_machine: "fleet-host-a")

      assert Enum.find(entries, &(&1["session"] == a))
      refute Enum.find(entries, &(&1["session"] == b))
    end

    test "who --project filters to sessions whose cwd is the dir or under it", %{conn: conn} do
      inside = unique_session()
      nested = unique_session()
      outside = unique_session()
      prefix_trap = unique_session()

      put_row(conn, inside, ts_seconds_ago(1), cwd: "/tmp/kazi-proj-a")
      put_row(conn, nested, ts_seconds_ago(1), cwd: "/tmp/kazi-proj-a/worktrees/t1")
      put_row(conn, outside, ts_seconds_ago(1), cwd: "/tmp/kazi-proj-b")
      put_row(conn, prefix_trap, ts_seconds_ago(1), cwd: "/tmp/kazi-proj-a-lookalike")

      assert {:ok, entries} =
               Bus.who(conn: conn, session: unique_session(), who_project: "/tmp/kazi-proj-a")

      sessions = Enum.map(entries, & &1["session"])
      assert inside in sessions
      assert nested in sessions
      refute outside in sessions
      refute prefix_trap in sessions
    end

    test "session_ttl_s/0 exposes the bucket TTL the folklore claimed", %{conn: _conn} do
      assert Bus.session_ttl_s() == 600
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

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

  defp wait_until_gone(_os_pid, 0), do: flunk("scratch process still visible to ps")

  defp wait_until_gone(os_pid, retries) do
    if Kazi.Bus.Liveness.proc_started_at(os_pid) == nil do
      :ok
    else
      Process.sleep(20)
      wait_until_gone(os_pid, retries - 1)
    end
  end

  defp put_row(conn, session, ts, overrides \\ []) do
    entry =
      %{
        "session" => session,
        "machine" => hostname(),
        "pid" => own_os_pid(),
        "started_at" => Liveness.proc_started_at(own_os_pid()),
        "liveness" => "active",
        "cwd" => File.cwd!(),
        "ts" => ts
      }
      |> Map.merge(Map.new(overrides, fn {k, v} -> {to_string(k), v} end))

    :ok = KV.put_value(conn, Provision.sessions_bucket(), sanitize(session), Jason.encode!(entry))
  end

  defp ts_seconds_ago(s),
    do: DateTime.utc_now() |> DateTime.add(-s, :second) |> DateTime.to_iso8601()

  defp sanitize(str), do: String.replace(str, ~r/[^a-zA-Z0-9_-]/, "_")

  defp unique_session, do: "liveness-test-#{System.unique_integer([:positive])}"

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp parse_nats_url("nats://" <> rest) do
    case String.split(rest, ":") do
      [host, port] -> {host, String.to_integer(port)}
      [host] -> {host, 4222}
    end
  end

  defp parse_nats_url(other), do: parse_nats_url("nats://" <> other)
end

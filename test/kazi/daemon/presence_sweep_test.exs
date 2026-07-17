defmodule Kazi.Daemon.PresenceSweepTest do
  @moduledoc """
  T55.11: the daemon-side presence sweep -- reaps rows for dead (or
  pid-reused) processes, re-heartbeats alive-but-quiet rows as `idle`, and
  NEVER touches rows recorded by other machines.

  UNTAGGED tests: the sweep GenServer survives an unreachable nats (a failed
  tick is a skipped tick, never a crash).

  `:nats`-TAGGED tests (excluded by default; `NATS_URL` required) drive
  `sweep/2` and the periodic GenServer against a real JetStream server.
  """
  use ExUnit.Case, async: false

  alias Gnat.Jetstream.API.KV
  alias Kazi.Bus.Liveness
  alias Kazi.Bus.Provision
  alias Kazi.Daemon.PresenceSweep

  # ===========================================================================
  # Untagged: a failed tick never crashes the sweep
  # ===========================================================================

  test "an unreachable nats makes a tick a no-op, not a crash" do
    pid =
      start_supervised!(
        {PresenceSweep,
         name: unique_name(:sweep_unreachable),
         connect_opts: %{host: "127.0.0.1", port: 1},
         interval_ms: 30}
      )

    # Let several ticks fire against the unreachable port.
    Process.sleep(150)
    assert Process.alive?(pid)
  end

  # ===========================================================================
  # :nats-tagged (excluded by default; NATS_URL required)
  # ===========================================================================

  describe "sweep/2 against a real NATS JetStream server" do
    @describetag :nats

    setup do
      {host, port} = parse_nats_url(System.fetch_env!("NATS_URL"))
      {:ok, conn} = Gnat.start_link(%{host: host, port: port})
      on_exit(fn -> if Process.alive?(conn), do: Gnat.stop(conn) end)
      :ok = Provision.provision(conn)
      %{conn: conn, host: host, port: port}
    end

    test "a row for a dead pid is reaped", %{conn: conn} do
      session = unique_session()
      put_row(conn, session, ts_seconds_ago(1), pid: dead_os_pid(), started_at: "gone")

      assert {:ok, %{reaped: reaped}} = PresenceSweep.sweep(conn)
      assert sanitize(session) in reaped

      {:ok, contents} = KV.contents(conn, Provision.sessions_bucket())
      refute Map.has_key?(contents, sanitize(session))
    end

    test "pid reuse (same pid, DIFFERENT start time) is treated as dead and reaped", %{
      conn: conn
    } do
      session = unique_session()

      put_row(conn, session, ts_seconds_ago(1),
        pid: own_os_pid(),
        started_at: "Thu Jan  1 00:00:00 1970"
      )

      assert {:ok, %{reaped: reaped}} = PresenceSweep.sweep(conn)
      assert sanitize(session) in reaped
    end

    test "an alive-but-quiet row is re-heartbeated as idle (never ages out)", %{conn: conn} do
      session = unique_session()
      put_row(conn, session, ts_seconds_ago(500))

      assert {:ok, %{idled: idled, reaped: reaped}} = PresenceSweep.sweep(conn)
      assert sanitize(session) in idled
      refute sanitize(session) in reaped

      value = KV.get_value(conn, Provision.sessions_bucket(), sanitize(session))
      assert {:ok, refreshed} = Jason.decode(value)
      assert refreshed["liveness"] == "idle"
      {:ok, ts, _} = DateTime.from_iso8601(refreshed["ts"])
      assert DateTime.diff(DateTime.utc_now(), ts, :second) < 60
      # Identity fields are preserved verbatim.
      assert refreshed["pid"] == own_os_pid()
      assert refreshed["started_at"] == Liveness.proc_started_at(own_os_pid())
    end

    test "a row the session itself refreshed recently stays active (untouched)", %{conn: conn} do
      session = unique_session()
      put_row(conn, session, ts_seconds_ago(1))

      assert {:ok, %{idled: idled, reaped: reaped}} = PresenceSweep.sweep(conn)
      refute sanitize(session) in idled
      refute sanitize(session) in reaped

      value = KV.get_value(conn, Provision.sessions_bucket(), sanitize(session))
      assert {:ok, entry} = Jason.decode(value)
      assert entry["liveness"] == "active"
    end

    test "a row for a REMOTE machine is never touched, even stale with a dead pid", %{
      conn: conn
    } do
      session = unique_session()

      put_row(conn, session, ts_seconds_ago(500),
        machine: "some-other-host",
        pid: dead_os_pid(),
        started_at: "gone"
      )

      before = KV.get_value(conn, Provision.sessions_bucket(), sanitize(session))

      assert {:ok, %{idled: idled, reaped: reaped}} = PresenceSweep.sweep(conn)
      refute sanitize(session) in idled
      refute sanitize(session) in reaped

      assert KV.get_value(conn, Provision.sessions_bucket(), sanitize(session)) == before
    end

    test "a pre-T55.11 row (live pid, no recorded start time) is left for the TTL", %{
      conn: conn
    } do
      session = unique_session()
      put_row(conn, session, ts_seconds_ago(500), started_at: nil)

      assert {:ok, %{idled: idled, reaped: reaped}} = PresenceSweep.sweep(conn)
      refute sanitize(session) in idled
      refute sanitize(session) in reaped
    end

    test "the supervised GenServer sweeps periodically", %{conn: conn, host: host, port: port} do
      session = unique_session()
      put_row(conn, session, ts_seconds_ago(1), pid: dead_os_pid(), started_at: "gone")

      start_supervised!(
        {PresenceSweep,
         name: unique_name(:sweep_periodic),
         connect_opts: %{host: host, port: port},
         interval_ms: 100}
      )

      # Generous window (~15s): this asserts the TIMER fires and reaps, not
      # how fast -- under a loaded machine (parallel suites) 5s flaked.
      assert eventually(
               fn ->
                 {:ok, contents} = KV.contents(conn, Provision.sessions_bucket())
                 not Map.has_key?(contents, sanitize(session))
               end,
               150
             ),
             "the periodic sweep never reaped the dead row"
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(100) && eventually(fun, retries - 1)
    end
  end

  defp own_os_pid, do: :os.getpid() |> to_string() |> String.to_integer()

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
    if Liveness.proc_started_at(os_pid) == nil do
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

  defp unique_session, do: "sweep-test-#{System.unique_integer([:positive])}"

  defp unique_name(label), do: :"#{label}_#{System.unique_integer([:positive])}"

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

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
  # Untagged: the stable-anchor pid (T55.14, issue #1164)
  #
  # The regression: presence recorded the EPHEMERAL CLI invocation's own pid
  # (`os_pid/0`), which exits milliseconds after writing the row -- so the
  # daemon sweep always found it gone and reaped every live session as
  # `dead-reaping`, and `idle` was unreachable. The fix records the STABLE
  # session anchor's pid (the nearest live ancestor), reusing the SAME walk
  # that backs the session id.
  #
  # These build a REAL process tree with a still-alive, NON-transient harness
  # (`sh <script>`) and a transient `-c` shell child standing in for the
  # short-lived CLI's parent. NOT a parked `bus watch`: a parked watch's own
  # pid already outlives the CLI call, so it proves nothing (sibling T55.13).
  # ===========================================================================

  describe "anchor identity resolves the stable ancestor, not the ephemeral writer" do
    test "a short-lived writer anchors on its still-alive ancestor -- verdicts alive, not dead" do
      {harness_pid, cshell_pid} = spawn_anchor_tree()

      # What a one-shot CLI whose parent is `cshell_pid` would record: the walk
      # skips the transient `-c` shell and lands on the alive harness.
      assert {anchor_pid, anchor_started_at} = Bus.anchor_identity_from(cshell_pid)
      assert anchor_pid == harness_pid
      assert is_binary(anchor_started_at)

      recorded = %{"pid" => anchor_pid, "started_at" => anchor_started_at}
      assert Liveness.verdict(recorded) == :alive

      # The transient wrapper (and the CLI under it) exits. The OLD behavior
      # recorded the writer's OWN identity, which now verdicts DEAD (the bug);
      # the fix's recorded anchor still verdicts ALIVE.
      cshell_started_at = Liveness.proc_started_at(cshell_pid)
      kill(cshell_pid)
      wait_until_gone(cshell_pid, 50)

      assert Liveness.verdict(%{"pid" => cshell_pid, "started_at" => cshell_started_at}) == :dead
      assert Liveness.verdict(recorded) == :alive
    end

    test "when the anchor itself is gone, the recorded identity verdicts dead (true-dead still reaps)" do
      {harness_pid, cshell_pid} = spawn_anchor_tree()

      assert {anchor_pid, anchor_started_at} = Bus.anchor_identity_from(cshell_pid)
      recorded = %{"pid" => anchor_pid, "started_at" => anchor_started_at}
      assert Liveness.verdict(recorded) == :alive

      # Kill the whole tree: a session whose anchor is genuinely gone must NOT
      # be kept alive by the fix.
      kill(cshell_pid)
      kill(harness_pid)
      wait_until_gone(harness_pid, 50)

      assert Liveness.verdict(recorded) == :dead
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

    test "presence upserts record the STABLE anchor pid + start time, liveness active", %{
      conn: conn
    } do
      session = unique_session()
      assert {:ok, entries} = Bus.who(conn: conn, session: session)

      assert own = Enum.find(entries, &(&1["session"] == session))
      # T55.14 (#1164): the recorded pid is the stable session anchor's (a live
      # ancestor of this process), NOT this process's own -- and it matches
      # `anchor_identity/0` exactly, so it verdicts :alive, never :dead.
      assert {anchor_pid, anchor_started_at} = Bus.anchor_identity()
      assert own["pid"] == anchor_pid
      assert own["started_at"] == anchor_started_at
      assert Liveness.verdict(own) == :alive
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

  # A real 2-level tree: a still-alive, NON-transient `sh <script>` harness
  # (the walk's stopping anchor) whose child is a transient `sh -c '...'` shell
  # (the throwaway wrapper a harness spawns per CLI command). The compound
  # command keeps `sh -c` from exec-optimizing into `sleep`, so the child stays
  # a genuine transient shell the walk must skip. Returns `{harness_pid,
  # cshell_pid}`; both are torn down on exit.
  defp spawn_anchor_tree do
    sh = System.find_executable("sh") || "/bin/sh"
    id = System.unique_integer([:positive])
    pidfile = Path.join(System.tmp_dir!(), "kazi_anchor_pids_#{id}")
    scriptfile = Path.join(System.tmp_dir!(), "kazi_anchor_#{id}.sh")

    # Run as `sh <scriptfile>` (NOT `sh -c`) so the harness itself is a
    # NON-transient shell the walk stops at. `$$` is the harness pid, `$1` the
    # pidfile; `$!` the transient `-c` child. The `; :` keeps `sh -c` from
    # exec-collapsing into `sleep`.
    File.write!(
      scriptfile,
      ~s|sh -c 'sleep 300; :' &\nprintf '%s %s\\n' "$$" "$!" > "$1"\nsleep 300\n|
    )

    port =
      Port.open({:spawn_executable, sh}, [:binary, :exit_status, args: [scriptfile, pidfile]])

    {harness_pid, cshell_pid} =
      Enum.reduce_while(1..100, nil, fn _, _ ->
        with {:ok, contents} <- File.read(pidfile),
             [h, c] <- contents |> String.trim() |> String.split(" ", trim: true) do
          {:halt, {String.to_integer(h), String.to_integer(c)}}
        else
          _ ->
            Process.sleep(20)
            {:cont, nil}
        end
      end) || flunk("anchor tree never reported its pids")

    on_exit(fn ->
      kill(cshell_pid)
      kill(harness_pid)
      if Port.info(port), do: Port.close(port)
      File.rm(pidfile)
      File.rm(scriptfile)
    end)

    {harness_pid, cshell_pid}
  end

  defp kill(os_pid) do
    System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

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

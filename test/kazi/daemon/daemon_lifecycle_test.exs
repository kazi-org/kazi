defmodule Kazi.Daemon.LifecycleTest do
  @moduledoc """
  T51.1 (ADR-0067 decision point 1): the daemon skeleton's lifecycle contract
  — process supervision + the Unix-socket control plane. This test starts the
  supervision tree IN-TEST (`Kazi.Daemon.start/1`), never the released
  binary, against tmp-scoped socket/pidfile/JetStream-store paths and a
  per-test nats port, all passed explicitly through `opts` — never the real
  `~/.kazi/daemon/` a developer's machine might already be using, and never
  the default nats port (T51.2, ADR-0067 decision point 2, wired
  `Kazi.Daemon.start/1` to also supervise nats-server unconditionally, so
  every daemon this test starts needs its own isolated bus store + port).

  `async: false`: real OS sockets and pidfiles are shared, mutable resources
  (not an Ecto sandbox transaction), so tests run serially to avoid flakiness
  from overlapping accept loops / file writes.
  """
  use ExUnit.Case, async: false

  alias Kazi.Daemon
  alias Kazi.Daemon.Probe
  alias Kazi.Daemon.Write
  alias Kazi.TestSupport.NatsPrereq

  # A throwaway read-model repo for the migrate-before-serve test: a FRESH
  # SQLite file the daemon's boot migration must create the tables in before a
  # `write` is served (mirrors `Kazi.ReadModel.MigrationLockTest`'s pattern).
  defmodule FreshRepo do
    use Ecto.Repo, otp_app: :kazi, adapter: Ecto.Adapters.SQLite3
  end

  # #1504: a throwaway read-model repo the daemon must START ITSELF (create the
  # file, open it) at boot -- deliberately NOT started up front, so the boot
  # seam's own `storage_up` + `start_link` (the standalone-binary path) is what
  # brings it up before a write is served.
  defmodule BootRepo do
    use Ecto.Repo, otp_app: :kazi, adapter: Ecto.Adapters.SQLite3
  end

  setup_all do
    NatsPrereq.ensure!()
    :ok
  end

  # Short, /tmp-rooted paths -- AF_UNIX socket paths have a small OS-level
  # length cap (~104 bytes on macOS); a nested `System.tmp_dir!()` path (often
  # under /var/folders/... on macOS) can blow that budget, so this deliberately
  # does NOT use `System.tmp_dir!()`.
  defp tmp_paths do
    id = System.unique_integer([:positive])
    {"/tmp/kazi_daemon_test_#{id}.sock", "/tmp/kazi_daemon_test_#{id}.pid"}
  end

  defp unique_name(label), do: :"#{label}_#{System.unique_integer([:positive])}"

  # T51.2: an isolated JetStream store dir + a random-ish high port per test,
  # so no test's supervised nats-server ever touches a developer's real
  # `~/.kazi/daemon/jetstream` or races another test's nats-server for a port.
  defp daemon_opts(sock_path, pid_path) do
    id = System.unique_integer([:positive])

    [
      sock_path: sock_path,
      pid_path: pid_path,
      name: unique_name(:daemon_sup),
      listener_name: unique_name(:daemon_listener),
      store_dir: "/tmp/kazi_daemon_test_js_#{id}",
      port: 20_000 + rem(id, 20_000)
    ]
  end

  defp expected_vsn do
    case Application.spec(:kazi, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end

  # Registers the daemon tree under ExUnit's OWN supervisor (the same pattern
  # `Kazi.Coordination.LeaseTableTest` uses) rather than linking it directly
  # to this (ephemeral) test process. `Kazi.Daemon.start/1` is itself an MFA
  # returning `{:ok, pid} | {:error, reason}`, so it slots straight into a
  # raw child spec. This sidesteps a real race: a daemon started directly in
  # the test process makes the test process its proc_lib "parent" -- when the
  # test process exits, the daemon tree tears itself down via that parent-exit
  # link BEFORE `on_exit` runs, so a manual `on_exit`-driven `Supervisor.stop`
  # call can collide with that already-in-flight shutdown.
  defp start_daemon!(sock_path, pid_path) do
    id = unique_name(:daemon)
    start_supervised!(%{id: id, start: {Daemon, :start, [daemon_opts(sock_path, pid_path)]}})
  end

  # ===========================================================================
  # (1) start the tree, connect, ping -- vsn matches Application.spec, uptime
  # present.
  # ===========================================================================

  test "start, connect, ping round-trips the version handshake" do
    {sock_path, pid_path} = tmp_paths()
    start_daemon!(sock_path, pid_path)

    assert File.exists?(sock_path)
    assert File.exists?(pid_path)
    assert File.read!(pid_path) == :os.getpid() |> to_string()

    assert {:ok, resp} = Probe.ping(sock_path)
    assert resp["ok"] == true
    assert resp["vsn"] == expected_vsn()
    assert is_integer(resp["pid"])
    assert is_integer(resp["uptime_s"])
    assert resp["uptime_s"] >= 0
  end

  test "an unknown op replies with a clean error, not a crash" do
    {sock_path, pid_path} = tmp_paths()
    start_daemon!(sock_path, pid_path)

    assert {:ok, resp} = Probe.request(sock_path, %{"op" => "not_a_real_op"})
    assert resp == %{"ok" => false, "error" => "unknown_op"}
  end

  # ===========================================================================
  # (2) shutdown op -- tree terminates, socket + pidfile gone.
  # ===========================================================================

  test "the shutdown op terminates the whole tree and removes socket + pidfile" do
    {sock_path, pid_path} = tmp_paths()
    assert {:ok, sup_pid} = Daemon.start(daemon_opts(sock_path, pid_path))
    ref = Process.monitor(sup_pid)

    assert File.exists?(sock_path)
    assert File.exists?(pid_path)

    assert {:ok, %{"ok" => true}} = Probe.request(sock_path, %{"op" => "shutdown"})

    assert_receive {:DOWN, ^ref, :process, ^sup_pid, _reason}, 2000
    refute File.exists?(sock_path)
    refute File.exists?(pid_path)
  end

  # ===========================================================================
  # (3) status-style connect against a missing socket path errors distinctly
  # from a stale one.
  # ===========================================================================

  test "probing a missing socket path reports :missing, distinct from a stale one" do
    {sock_path, _pid_path} = tmp_paths()

    refute File.exists?(sock_path)
    assert Probe.probe(sock_path) == :missing
    assert {:error, _reason} = Probe.ping(sock_path)
  end

  # ===========================================================================
  # (4) a stale socket file (create the file, no listener) is detected as dead
  # (connect refused) -- the probe helper reports it, and `start/1` (the path
  # `kazi daemon start` calls) cleans it up rather than refusing.
  # ===========================================================================

  test "a stale socket file is detected as dead and start/1 replaces it" do
    {sock_path, pid_path} = tmp_paths()
    File.write!(sock_path, "")

    assert Probe.probe(sock_path) == :dead

    assert Probe.probe(sock_path) !=
             Probe.probe(
               "/tmp/kazi_daemon_test_missing_#{System.unique_integer([:positive])}.sock"
             )

    start_daemon!(sock_path, pid_path)

    assert Probe.probe(sock_path) == :alive
    assert {:ok, %{"ok" => true}} = Probe.ping(sock_path)
  end

  # ===========================================================================
  # (5) double-start against a live socket refuses.
  # ===========================================================================

  test "starting a second daemon against a live socket refuses, naming the vsn" do
    {sock_path, pid_path} = tmp_paths()
    start_daemon!(sock_path, pid_path)

    assert {:error, {:already_running, vsn}} = Daemon.start(daemon_opts(sock_path, pid_path))
    assert vsn == expected_vsn()
  end

  # ===========================================================================
  # (6) T52.4 (ADR-0068 point 2): migrate-before-serve. The supervisor runs the
  # boot migration ONCE, then starts the write server ONLY after it returns,
  # ordered before the listener.
  # ===========================================================================

  test "the write server starts only AFTER the boot migration returns, and is in the tree" do
    {sock_path, pid_path} = tmp_paths()
    {:ok, order} = Agent.start_link(fn -> [] end)

    opts =
      daemon_opts(sock_path, pid_path) ++
        [
          migrate_fun: fn ->
            Agent.update(order, &[:migrated | &1])
            :ok
          end,
          write_on_start: fn -> Agent.update(order, &[:write_started | &1]) end
        ]

    sup_pid = start_supervised!(%{id: unique_name(:daemon), start: {Daemon, :start, [opts]}})

    # The migration recorded BEFORE the write server's init ran.
    assert Enum.reverse(Agent.get(order, & &1)) == [:migrated, :write_started]

    # The write server IS a supervised child of the daemon tree.
    child_ids = for {id, _pid, _type, _mods} <- Supervisor.which_children(sup_pid), do: id
    assert Kazi.Daemon.Write in child_ids
  end

  test "a fresh read-model is migrated before the daemon serves a write ('no such table' gone)" do
    {sock_path, pid_path} = tmp_paths()
    db_path = "/tmp/kazi_daemon_migrate_#{System.unique_integer([:positive])}.db"
    on_exit(fn -> File.rm(db_path) end)

    start_supervised!({FreshRepo, database: db_path, pool_size: 1, busy_timeout: 5_000})

    request = %{
      "op" => "write",
      "batch" => [
        %{
          "kind" => "insert",
          "schema" => "Kazi.ReadModel.Iteration",
          "fields" => %{
            "goal_ref" => "g-migrate",
            "iteration_index" => 0,
            "predicate_vector" => %{},
            "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ]
    }

    # BEFORE the daemon migrates it, the fresh db has no iterations table.
    assert %{"ok" => false} = Write.handle(request, repo: FreshRepo)

    # The daemon's boot migration (point 2) migrates FreshRepo before it serves.
    # FreshRepo is a test module, so point the migration at kazi's OWN migrations
    # dir (FreshRepo's own priv path holds none) -- otherwise identical to the
    # production `Kazi.ReadModel.Migrate.run/2` boot path.
    migrations_path = Ecto.Migrator.migrations_path(Kazi.Repo)

    opts =
      daemon_opts(sock_path, pid_path) ++
        [
          migrate_fun: fn ->
            Kazi.ReadModel.Migrate.run(FreshRepo, migrations_path: migrations_path)
          end
        ]

    start_supervised!(%{id: unique_name(:daemon), start: {Daemon, :start, [opts]}})

    assert Probe.probe(sock_path) == :alive

    # A write issued right after the daemon is alive now succeeds.
    assert %{"ok" => true, "applied" => 1} = Write.handle(request, repo: FreshRepo)
  end

  # ===========================================================================
  # (7) #1504 (the WRITER half of #1483): the daemon is the ONE read-model
  # writer/migrator (ADR-0068). Under a standalone binary the app supervision
  # tree never stood `Kazi.Repo` up, so the daemon must START the writer itself
  # -- create the file, open it, keep it running -- BEFORE it migrates and
  # BEFORE any write is served. Absent this the boot migration hit "could not
  # lookup Ecto repo Kazi.Repo because it was not started", degraded to
  # no-persistence, and the daemon SERVED anyway with every write silently lost.
  # ===========================================================================

  test "the daemon starts an unstarted read-model writer, migrates it, and a write round-trips" do
    {sock_path, pid_path} = tmp_paths()
    db_path = "/tmp/kazi_daemon_writer_#{System.unique_integer([:positive])}.db"

    # Configure BootRepo's db so the daemon's REAL `ensure_repo_started` path
    # (`storage_up(repo.config())` + `repo.start_link()`) resolves it. The repo
    # is deliberately NOT started here -- the daemon boot seam must bring it up.
    Application.put_env(:kazi, BootRepo, database: db_path, pool_size: 1, busy_timeout: 5_000)

    on_exit(fn ->
      Application.delete_env(:kazi, BootRepo)
      File.rm(db_path)
    end)

    refute repo_running?(BootRepo)

    request = %{
      "op" => "write",
      "batch" => [
        %{
          "kind" => "insert",
          "schema" => "Kazi.ReadModel.Iteration",
          "fields" => %{
            "goal_ref" => "g-writer",
            "iteration_index" => 0,
            "predicate_vector" => %{},
            "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      ]
    }

    # `migrate_repo: BootRepo` drives the REAL default repo-start (storage_up +
    # start_link) at BootRepo; only the migration is seamed to kazi's own
    # migrations dir (BootRepo's own priv path holds none), exactly as (6).
    migrations_path = Ecto.Migrator.migrations_path(Kazi.Repo)

    opts =
      daemon_opts(sock_path, pid_path) ++
        [
          migrate_repo: BootRepo,
          migrate_fun: fn ->
            Kazi.ReadModel.Migrate.run(BootRepo, migrations_path: migrations_path)
          end
        ]

    start_supervised!(%{id: unique_name(:daemon), start: {Daemon, :start, [opts]}})

    assert Probe.probe(sock_path) == :alive
    # The daemon started the writer ...
    assert repo_running?(BootRepo)
    # ... migrated it, and a write now round-trips against it (no "could not
    # lookup Ecto repo", no "continuing without persistence").
    assert %{"ok" => true, "applied" => 1} = Write.handle(request, repo: BootRepo)
  end

  # #1504 fail-loud: a writer that genuinely CANNOT start must make the daemon
  # REFUSE to serve, never come up healthy-looking with no write path. The
  # repo-start failure propagates out of the supervisor `init/1`, so
  # `Kazi.Daemon.start/1` returns `{:error, _}` and no socket is ever bound --
  # the silent, write-less "continuing without persistence" mode is structurally
  # impossible on this path.
  test "a writer that cannot start makes the daemon refuse to serve" do
    {sock_path, pid_path} = tmp_paths()

    opts =
      daemon_opts(sock_path, pid_path) ++
        [repo_start_fun: fn -> raise "read-model writer unavailable" end]

    assert {:error, _reason} = Daemon.start(opts)
    assert Probe.probe(sock_path) == :missing
  end

  defp repo_running?(repo) do
    is_pid(Process.whereis(repo)) or is_pid(GenServer.whereis(repo))
  end
end

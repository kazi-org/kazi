defmodule Kazi.CLI.MigrateReadModelTest do
  @moduledoc """
  T52.6 (ADR-0068 points 2 & 5): the single-migrator cutover at the CLI
  boundary. `Kazi.CLI.migrate_read_model/1` must DEFER to a live daemon (which
  has already migrated the read-model once at its own startup, T52.4) and run
  the boot migration itself ONLY when no daemon is present.

  The daemon presence is stubbed via the `:probe` seam and the migrator is
  observed via the `:migrate_fun` seam (mirroring the daemon supervisor's
  `:migrate_fun`), so no real socket, connection, or read-model file is touched.
  """
  use ExUnit.Case, async: true

  # A migrator recorder: counts invocations so a test can prove the boot
  # migration ran (no daemon) or never ran (`:alive`).
  defp recording_migrate_fun do
    ref = make_ref()
    key = {__MODULE__, ref}
    :persistent_term.put(key, 0)

    fun = fn ->
      :persistent_term.put(key, :persistent_term.get(key) + 1)
      :ok
    end

    count = fn -> :persistent_term.get(key) end
    {fun, count}
  end

  describe "migrate_read_model/1 -- a live daemon owns migration" do
    test "with a stubbed :alive probe it performs NO migration and opens no write connection" do
      {migrate_fun, count} = recording_migrate_fun()

      assert Kazi.CLI.migrate_read_model(
               probe: fn _sock -> :alive end,
               sock_path: "/nonexistent/daemon.sock",
               migrate_fun: migrate_fun
             ) == :ok

      # Zero migration runs: the process deferred entirely to the daemon and
      # never opened the read-model file read-write.
      assert count.() == 0
    end
  end

  describe "migrate_read_model/1 -- no daemon, today's behavior stands" do
    test "with a :dead probe it runs the boot migration exactly once" do
      {migrate_fun, count} = recording_migrate_fun()

      assert Kazi.CLI.migrate_read_model(
               probe: fn _sock -> :dead end,
               sock_path: "/nonexistent/daemon.sock",
               migrate_fun: migrate_fun
             ) == :ok

      assert count.() == 1
    end

    test "with a :missing probe (no socket file) it also migrates once" do
      {migrate_fun, count} = recording_migrate_fun()

      assert Kazi.CLI.migrate_read_model(
               probe: fn _sock -> :missing end,
               sock_path: "/nonexistent/daemon.sock",
               migrate_fun: migrate_fun
             ) == :ok

      assert count.() == 1
    end
  end

  describe "migrate_read_model/1 -- two binaries, one daemon" do
    test "two concurrent boots against one :alive daemon produce zero migration runs between them" do
      # Simulate two kazi binaries (different migration sets in the field)
      # booting at the same time while ONE daemon is up: the daemon migrated
      # once (T52.4); neither client migrates. Both defer, zero runs here.
      {fun_a, count_a} = recording_migrate_fun()
      {fun_b, count_b} = recording_migrate_fun()

      alive = fn _sock -> :alive end
      sock = "/nonexistent/daemon.sock"

      tasks =
        for {fun, _c} <- [{fun_a, count_a}, {fun_b, count_b}] do
          Task.async(fn ->
            Kazi.CLI.migrate_read_model(probe: alive, sock_path: sock, migrate_fun: fun)
          end)
        end

      assert Enum.map(tasks, &Task.await/1) == [:ok, :ok]
      assert count_a.() == 0
      assert count_b.() == 0
    end
  end
end

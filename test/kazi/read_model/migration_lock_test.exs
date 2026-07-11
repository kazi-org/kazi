defmodule Kazi.ReadModel.MigrationLockTest do
  # Pins issue #1019 part 2: a peer holding the SQLite lock on the shared
  # read-model must cost a boot a BOUNDED wait, never a hang. Holds the lock
  # from a competing raw connection on a throwaway tmp db, then calls the real
  # migration path and asserts it degrades within the bound instead of
  # blocking for as long as the lock holder lives.
  use ExUnit.Case, async: false

  defmodule LockRepo do
    use Ecto.Repo, otp_app: :kazi, adapter: Ecto.Adapters.SQLite3
  end

  @moduletag :tmp_dir

  test "a locked db degrades within the bound instead of hanging", %{tmp_dir: tmp_dir} do
    db_path = Path.join(tmp_dir, "migration_lock.db")

    {:ok, conn} = Exqlite.Sqlite3.open(db_path)
    :ok = Exqlite.Sqlite3.execute(conn, "BEGIN IMMEDIATE")
    :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE lock_holder(id INTEGER)")

    start_supervised!({LockRepo, database: db_path, pool_size: 1, busy_timeout: 60_000})

    empty_migrations_dir = Path.join(tmp_dir, "migrations")
    File.mkdir_p!(empty_migrations_dir)

    {elapsed_us, result} =
      :timer.tc(fn ->
        Kazi.ReadModel.Migrate.run(LockRepo,
          timeout_ms: 2_000,
          migrations_path: empty_migrations_dir
        )
      end)

    Exqlite.Sqlite3.execute(conn, "ROLLBACK")
    Exqlite.Sqlite3.close(conn)

    assert result == {:error, :read_model_unavailable}
    assert elapsed_us < 10_000_000, "migration must degrade within the bound, not hang"
  end
end

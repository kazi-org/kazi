defmodule Kazi.ReadModel.SchemaVersionGuardTest do
  # Pins issue #1019 part 3: an OLDER kazi binary must never migrate (or
  # otherwise contend with) a NEWER read-model schema. Stamps a tmp db with a
  # future `PRAGMA user_version`, boots the migration path against it, and
  # asserts it degrades to no-persistence naming the mismatch -- and that the
  # db's stamp is left untouched.
  use ExUnit.Case, async: false

  defmodule VersionRepo do
    use Ecto.Repo, otp_app: :kazi, adapter: Ecto.Adapters.SQLite3
  end

  @moduletag :tmp_dir
  @future_version 99_999_999_999_999

  test "a newer-than-known schema stamp refuses to migrate and stays untouched", %{
    tmp_dir: tmp_dir
  } do
    db_path = Path.join(tmp_dir, "schema_version.db")

    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    :ok =
      Exqlite.Sqlite3.execute(
        conn,
        "CREATE TABLE kazi_schema_meta (version INTEGER NOT NULL)"
      )

    :ok =
      Exqlite.Sqlite3.execute(
        conn,
        "INSERT INTO kazi_schema_meta (version) VALUES (#{@future_version})"
      )

    Exqlite.Sqlite3.close(conn)

    start_supervised!({VersionRepo, database: db_path, pool_size: 1})

    empty_migrations_dir = Path.join(tmp_dir, "migrations")
    File.mkdir_p!(empty_migrations_dir)

    assert {:error, {:newer_schema, @future_version, bin_version}} =
             Kazi.ReadModel.Migrate.run(VersionRepo, migrations_path: empty_migrations_dir)

    assert is_integer(bin_version)

    {:ok, verify_conn} = Exqlite.Sqlite3.open(db_path)
    {:ok, stmt} = Exqlite.Sqlite3.prepare(verify_conn, "SELECT version FROM kazi_schema_meta")
    {:row, [stamped]} = Exqlite.Sqlite3.step(verify_conn, stmt)
    Exqlite.Sqlite3.close(verify_conn)

    assert stamped == @future_version
  end
end

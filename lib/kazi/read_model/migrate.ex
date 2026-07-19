defmodule Kazi.ReadModel.Migrate do
  @moduledoc """
  The read-model's boot-time migration path (issue #1019): every `kazi`
  invocation on a machine shares one SQLite file (`~/.kazi/kazi.db`), so
  during a release window several DIFFERENT kazi versions can contend on the
  Ecto migration lock at the same moment. Two failure modes were observed in
  the wild: a newer binary's `Kazi.ReadModel.Guard` degrading (contained but
  blind) and an OLDER binary hanging indefinitely at 0% CPU because it has no
  bounded wait at all.

  `run/2` closes both gaps in one bounded step:

    * a version stamp (a `kazi_schema_meta` row set to the highest migration
      timestamp this binary knows -- NOT `PRAGMA user_version`, which SQLite
      stores as a signed 32-bit integer, too narrow for an Ecto migration
      timestamp) is checked BEFORE migrating — an older binary that finds a
      NEWER stamp than it knows refuses to touch the db (never migrates
      down, never blocks) and degrades Guard-style instead;
    * the whole check-then-migrate sequence runs under
      `Kazi.ReadModel.Guard.run/3` with a SHORT bound (a few seconds, not the
      read/write path's 60s) — a peer holding the SQLite lock costs this
      boot a few seconds of no-persistence, never a hang.

  Both failure modes degrade through the SAME `{:error, :read_model_unavailable}`
  (or `{:error, {:newer_schema, db_version, bin_version}}` for the version
  mismatch, so a caller can tell the two apart) — the one degradation
  mechanism the read-model already uses everywhere (L-0035); this module
  invents no second one.
  """

  require Logger

  alias Kazi.ReadModel.Guard

  # A few seconds, not the read/write path's 60s (Kazi.Repo's busy_timeout):
  # a peer holding the migration lock during a release window should cost
  # this boot a few seconds of no-persistence, never a multi-minute hang.
  @default_timeout_ms 5_000

  @doc """
  Migrates `repo` up, bounded by `timeout_ms` (default #{@default_timeout_ms}ms).

  Returns `:ok` on a clean (or already up-to-date) migration. Degrades —
  never raises, never blocks past the bound — to:

    * `{:error, :read_model_unavailable}` when the lock could not be
      acquired (or any other failure) within the bound;
    * `{:error, {:newer_schema, db_version, bin_version}}` when the db's
      stamped schema version is newer than this binary knows — the db is
      left untouched (no migration attempted, no down-migration, ever).

  `opts`:

    * `:timeout_ms` — override the bound (tests use a short one).
    * `:migrations_path` — override the migrations directory (tests point
      this at a fixture; production uses the repo's own priv path).
  """
  @spec run(module(), keyword()) ::
          :ok
          | {:error, :read_model_unavailable}
          | {:error, {:newer_schema, integer(), integer()}}
  def run(repo, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    migrations_path = Keyword.get(opts, :migrations_path) || Ecto.Migrator.migrations_path(repo)

    Guard.run(
      "migrate",
      fn -> migrate_or_refuse(repo, migrations_path) end,
      timeout_ms
    )
  end

  defp migrate_or_refuse(repo, migrations_path) do
    bin_version = binary_version(migrations_path)

    case db_stamped_version(repo) do
      db_version when is_integer(db_version) and db_version > bin_version ->
        Logger.warning(fn ->
          "read-model schema v#{db_version} is newer than this binary " <>
            "(v#{bin_version}); running without persistence -- upgrade kazi"
        end)

        {:error, {:newer_schema, db_version, bin_version}}

      _not_newer ->
        _ = Ecto.Migrator.run(repo, migrations_path, :up, all: true)
        stamp_version(repo, bin_version)
        :ok
    end
  end

  @doc """
  The highest migration timestamp this binary ships (the numeric prefix of
  every `priv/repo/migrations/<timestamp>_*.exs` file). Absent any migration
  file (a fixture dir in a test), 0 — never newer than any legitimately-stamped
  db.

  Public (T52.2, ADR-0068): the write path compares THIS against a daemon's
  reported `schema_vsn` via `Kazi.ReadModel.SchemaSkew.classify/2` to decide the
  version-skew branch.
  """
  @spec binary_version(Path.t()) :: integer()
  def binary_version(migrations_path \\ Ecto.Migrator.migrations_path(Kazi.Repo)) do
    migrations_path
    |> File.ls()
    |> case do
      {:ok, files} -> files
      {:error, _} -> []
    end
    |> Enum.flat_map(fn file ->
      case Integer.parse(file) do
        {version, _rest} -> [version]
        :error -> []
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  # A dedicated single-row table, NOT `PRAGMA user_version`: SQLite stores that
  # pragma as a signed 32-bit integer, and kazi's migration "version" is an
  # Ecto migration TIMESTAMP (e.g. 20260709210000, 14 digits) -- already past
  # the pragma's ~2.1 billion ceiling. A real table has no such limit.
  @meta_table "kazi_schema_meta"

  @doc """
  The schema version stamped in the db's `kazi_schema_meta` row, or `nil` when
  the db is unstamped (a freshly-created, pre-migration db) — never a real
  version, so a brand new db always migrates.

  Public (T52.2, ADR-0068): the daemon reads this to answer the control-socket
  `ping`'s `schema_vsn` field (the single writer reports the schema it holds).
  """
  @spec db_stamped_version(module()) :: integer() | nil
  def db_stamped_version(repo) do
    Ecto.Adapters.SQL.query!(
      repo,
      "CREATE TABLE IF NOT EXISTS #{@meta_table} (version INTEGER NOT NULL)",
      []
    )

    case Ecto.Adapters.SQL.query(repo, "SELECT version FROM #{@meta_table} LIMIT 1", []) do
      {:ok, %{rows: [[version]]}} when is_integer(version) -> version
      _ -> nil
    end
  end

  defp stamp_version(repo, version) do
    Ecto.Adapters.SQL.query!(repo, "DELETE FROM #{@meta_table}", [])
    Ecto.Adapters.SQL.query!(repo, "INSERT INTO #{@meta_table} (version) VALUES (?1)", [version])
    :ok
  end
end

defmodule Kazi.ReadModel.TransactionModeTest do
  @moduledoc """
  T59.5 (#1025/#1186), class 5a. Pins the read-model's write path to the
  busy-TOLERANT transaction mode.

  `Kazi.CLIPlanBudgetSuggestionTest` flaked with `Exqlite.Error: Database busy`
  on the `proposed_goals` upsert (via `Kazi.Authoring.persist/3`) under a
  parallel suite, even though `Kazi.Repo` sets `busy_timeout: 60_000`. The
  reason is the transaction MODE, not the timeout:

    * exqlite's default is a DEFERRED transaction: `BEGIN` takes only a read
      lock and upgrades to a write lock on the first write. If another
      connection holds the writer at that instant, SQLite returns SQLITE_BUSY
      *immediately* and does NOT invoke the busy handler (honoring
      `busy_timeout` there could require rolling back the read snapshot and
      break serializability). So `busy_timeout` never covered a
      read-then-write transaction.
    * An IMMEDIATE transaction takes the write lock at `BEGIN`, where the busy
      handler DOES run, so a contended writer WAITS up to `busy_timeout`
      instead of erroring.

  The fix is `config :kazi, Kazi.Repo, default_transaction_mode: :immediate`
  (config.exs). This test pins that config AND demonstrates the underlying
  asymmetry directly against raw connections, so a revert to the deferred
  default fails here.
  """
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3

  @busy_timeout_ms 300

  # A generous slack below/above @busy_timeout_ms: the deferred upgrade must
  # error in well under the timeout (it never waits); the immediate begin must
  # error only after waiting at least (nearly) the whole timeout.
  @fast_ceiling_ms 150
  @wait_floor_ms 250

  test "Kazi.Repo is configured for IMMEDIATE transactions (busy-tolerant write path)" do
    assert Keyword.get(Kazi.Repo.config(), :default_transaction_mode) == :immediate,
           "Kazi.Repo must run transactions in :immediate mode so busy_timeout covers " <>
             "the read-then-write path (T59.5, #1025/#1186); a DEFERRED transaction " <>
             "gets SQLITE_BUSY on the write upgrade with busy_timeout bypassed"
  end

  describe "deferred vs immediate against a held writer (the mechanism)" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "kazi-txmode-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      db = Path.join(dir, "t.db")
      on_exit(fn -> File.rm_rf!(dir) end)

      # Seed the schema on its own connection and close it, so the table exists
      # for every connection below and no schema lock lingers.
      {:ok, seed} = Sqlite3.open(db)
      :ok = Sqlite3.execute(seed, "PRAGMA journal_mode=WAL")
      :ok = Sqlite3.execute(seed, "CREATE TABLE t(id INTEGER PRIMARY KEY)")
      :ok = Sqlite3.close(seed)

      # A second connection holds the write lock for the whole test and never
      # commits, so every attempt below contends for a writer that is present.
      {:ok, holder} = Sqlite3.open(db)
      :ok = Sqlite3.set_busy_timeout(holder, @busy_timeout_ms)
      :ok = Sqlite3.execute(holder, "BEGIN IMMEDIATE")
      :ok = Sqlite3.execute(holder, "INSERT INTO t(id) VALUES (1)")
      on_exit(fn -> Sqlite3.close(holder) end)

      %{db: db}
    end

    test "a DEFERRED transaction's write upgrade errors IMMEDIATELY (busy_timeout bypassed)",
         %{db: db} do
      {:ok, conn} = Sqlite3.open(db)
      :ok = Sqlite3.set_busy_timeout(conn, @busy_timeout_ms)
      # Deferred: read lock first, then attempt the write upgrade while the
      # holder owns the writer.
      :ok = Sqlite3.execute(conn, "BEGIN")
      :ok = Sqlite3.execute(conn, "SELECT count(*) FROM t")

      {elapsed_us, result} =
        :timer.tc(fn -> Sqlite3.execute(conn, "INSERT INTO t(id) VALUES (2)") end)

      Sqlite3.close(conn)

      assert match?({:error, _}, result),
             "expected the deferred write upgrade to be refused while a writer is held"

      # The defining symptom: it did NOT wait out busy_timeout.
      assert elapsed_us / 1000 < @fast_ceiling_ms,
             "deferred upgrade should error immediately (busy_timeout bypassed), " <>
               "but it waited #{Float.round(elapsed_us / 1000, 1)}ms"
    end

    test "an IMMEDIATE transaction WAITS for the writer (busy_timeout honored)", %{db: db} do
      {:ok, conn} = Sqlite3.open(db)
      :ok = Sqlite3.set_busy_timeout(conn, @busy_timeout_ms)

      # Immediate: takes the write lock at BEGIN, where the busy handler runs, so
      # it waits ~busy_timeout for the held writer before giving up.
      {elapsed_us, result} =
        :timer.tc(fn -> Sqlite3.execute(conn, "BEGIN IMMEDIATE") end)

      Sqlite3.close(conn)

      # The holder never releases, so it still ends in an error here — but only
      # AFTER honoring busy_timeout. That waiting is exactly what lets a real
      # contended writer succeed once the peer's short write burst commits.
      assert match?({:error, _}, result)

      assert elapsed_us / 1000 >= @wait_floor_ms,
             "immediate BEGIN should honor busy_timeout (wait ~#{@busy_timeout_ms}ms), " <>
               "but it returned after only #{Float.round(elapsed_us / 1000, 1)}ms"
    end
  end
end

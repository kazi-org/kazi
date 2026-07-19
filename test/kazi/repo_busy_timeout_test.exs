defmodule Kazi.RepoBusyTimeoutTest do
  # Every kazi process on a machine shares one read-model DB
  # (`~/.kazi/kazi.db`), so concurrent `kazi apply` runs contend for the
  # single SQLite WAL writer. exqlite's 2s default busy_timeout wedged a
  # fleet of 5+ concurrent processes (2026-07-09 incident); this pins the
  # generous timeout so it cannot silently regress to the default.
  use ExUnit.Case, async: true

  test "the shared read-model connection rides out concurrent writers" do
    busy_timeout = Application.get_env(:kazi, Kazi.Repo)[:busy_timeout]

    assert is_integer(busy_timeout) and busy_timeout >= 30_000,
           "Kazi.Repo needs a generous :busy_timeout (got #{inspect(busy_timeout)}); " <>
             "the exqlite 2s default wedges concurrent kazi processes on ~/.kazi/kazi.db"
  end
end

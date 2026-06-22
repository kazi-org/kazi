# The `test` mix alias (mix.exs) runs `ecto.create` + `ecto.migrate` before this
# file, so the SQLite read-model exists and is migrated with no external DB step
# (T0.9 CI compatibility). Here we just put the Sandbox into :manual mode for
# per-test isolation.
Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, :manual)

ExUnit.start()

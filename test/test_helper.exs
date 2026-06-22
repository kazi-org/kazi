# The `test` mix alias (mix.exs) runs `ecto.create` + `ecto.migrate` before this
# file, so the SQLite read-model exists and is migrated with no external DB step
# (T0.9 CI compatibility). Here we just put the Sandbox into :manual mode for
# per-test isolation.
Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, :manual)

# Integration tests tagged `:nats` need a real NATS JetStream server and are
# EXCLUDED by default so the standard `mix test` stays hermetic (no NATS, no
# network). They run only when `NATS_URL` is set in the environment:
#
#     NATS_URL=nats://127.0.0.1:4222 mix test --include nats
#
# `--include nats` overrides the default exclusion; the test itself reads
# `NATS_URL` to connect (see test/kazi/coordination/lease/nats_test.exs).
nats_opts = if System.get_env("NATS_URL"), do: [], else: [exclude: [:nats]]

ExUnit.start(nats_opts)

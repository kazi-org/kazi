# Playwright dashboard server (T3.6b).
#
# Boots the :kazi app (Repo + PubSub + Endpoint) in the test env and puts the
# read-model's SQLite Sandbox into SHARED mode owned by this long-lived script
# process. The endpoint serves web requests in their own processes; shared mode
# lets those processes — and the test-only /test/seed + /test/reset endpoints —
# see the same connection, so the goal board renders seeded data in a real
# browser while staying inside one isolated test transaction (hermetic: no NATS,
# no harness).
#
# `mix run --no-halt priv/playwright/server.exs` keeps the VM alive, but the
# shared-mode owner must be a process that does NOT exit — a connection reverts to
# :manual the moment its owner terminates. So this script checks the connection
# out, shares it, then blocks forever, remaining the owner for the whole run.

alias Ecto.Adapters.SQL.Sandbox

# Check out a connection and share it with every process (web requests + seeds).
:ok = Sandbox.checkout(Kazi.Repo)
Sandbox.mode(Kazi.Repo, {:shared, self()})

# Start empty: the first spec to seed/reset sets the state it needs.
Kazi.Repo.delete_all(Kazi.ReadModel.Iteration)

# Block this (owner) process for the lifetime of the Playwright run so the shared
# checkout never reverts to :manual. `mix run --no-halt` would otherwise let the
# script process finish while the node stays up — terminating the owner.
Process.sleep(:infinity)

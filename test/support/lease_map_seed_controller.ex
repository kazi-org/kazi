defmodule KaziWeb.LeaseMapSeedController do
  @moduledoc """
  Test-only seed endpoints for the presence/lease map Playwright harness (T3.6c).

  Compiled ONLY in the test env (`test/support` is on the `:test` elixirc path)
  and routed ONLY when `Mix.env() == :test` (see `KaziWeb.Router`), so this never
  ships. It drives the injected `KaziWeb.CoordinationFixtureSource` the lease-map
  LiveView renders from — no NATS, no transport (ADR-0011 §3):

    * `POST /test/leases/seed` pushes a deterministic populated snapshot (two
      present instances, their intents, two active leases) the golden-path spec
      asserts on;
    * `POST /test/leases/release` pushes a fresh snapshot with the billing lease +
      `kazi-2` dropped, simulating a lease release — the subscribed view re-renders
      live, which is exactly what the spec verifies.

  The Playwright server (`priv/playwright/server.exs`) points `:lease_map_source`
  at the fixture and starts it before the browser run, so a push here is visible to
  the LiveView across processes while staying hermetic.
  """
  use KaziWeb, :controller

  alias KaziWeb.CoordinationFixtureSource, as: Fixture
  alias KaziWeb.CoordinationSource

  @doc "Pushes the populated presence/lease snapshot. Returns `200 seeded`."
  def seed(conn, _params) do
    :ok = Fixture.put_snapshot(populated_snapshot())
    text(conn, "seeded")
  end

  @doc "Pushes the post-release snapshot (billing lease + kazi-2 gone). Returns `200 released`."
  def release(conn, _params) do
    :ok = Fixture.put_snapshot(released_snapshot())
    text(conn, "released")
  end

  defp populated_snapshot do
    CoordinationSource.build(
      [
        %{instance: "kazi-1", announced_at_ms: 1_000},
        %{instance: "kazi-2", announced_at_ms: 1_100}
      ],
      [
        %{instance: "kazi-1", resource: "lib-auth", announced_at_ms: 1_000},
        %{instance: "kazi-2", resource: "lib-billing", announced_at_ms: 1_100}
      ],
      [
        lease("lib-auth", "kazi-1"),
        lease("lib-billing", "kazi-2")
      ]
    )
  end

  defp released_snapshot do
    CoordinationSource.build(
      [%{instance: "kazi-1", announced_at_ms: 1_000}],
      [%{instance: "kazi-1", resource: "lib-auth", announced_at_ms: 1_000}],
      [lease("lib-auth", "kazi-1")]
    )
  end

  defp lease(key, holder) do
    %Kazi.Coordination.Lease{key: key, holder: holder, revision: 1, expires_at_ms: 31_000}
  end
end

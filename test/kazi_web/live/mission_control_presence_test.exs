defmodule KaziWeb.MissionControlPresenceTest do
  @moduledoc """
  T51.5 (ADR-0073 §4, UC-038): the starmap's SESSIONS rail renders live bus
  presence, read from the SAME injectable `KaziWeb.CoordinationSource` the
  `/leases` map consumes (T55.3) -- so the rail is not built twice.

  Hermetic: the roster is the in-memory `KaziWeb.CoordinationFixtureSource`
  injected via `:lease_map_source`; no real daemon, no NATS.
  """
  use KaziWeb.ConnCase, async: false

  alias KaziWeb.CoordinationFixtureSource, as: Fixture
  alias KaziWeb.CoordinationSource

  setup do
    prev = Application.get_env(:kazi, :lease_map_source)
    Application.delete_env(:kazi, :lease_map_source)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:kazi, :lease_map_source, prev),
        else: Application.delete_env(:kazi, :lease_map_source)
    end)

    :ok
  end

  test "the SESSIONS rail renders bus presence rows: session, machine, last-seen",
       %{conn: conn} do
    Application.put_env(:kazi, :lease_map_source, Fixture)

    roster =
      CoordinationSource.build(
        [
          %{
            instance: "session-a",
            announced_at_ms: 1_752_600_000_000,
            machine: "machine-1",
            last_seen: "12s ago"
          },
          %{
            instance: "session-b",
            announced_at_ms: 1_752_600_010_000,
            machine: "machine-2",
            last_seen: "3m ago"
          }
        ],
        [],
        []
      )

    start_supervised!({Fixture, snapshot: roster})

    {:ok, _view, html} = live(conn, ~p"/starmap?debug=1")

    assert html =~ ~s(id="mc-sessions-list")
    assert html =~ ~s(id="presence-session-a")
    assert html =~ ~s(data-machine="machine-1")
    assert html =~ ~s(data-last-seen="12s ago")
    assert html =~ ~s(id="presence-session-b")
    assert html =~ ~s(data-machine="machine-2")
    assert html =~ ~s(data-last-seen="3m ago")
    refute html =~ "No sessions present"
  end

  test "with no sessions present the rail shows an empty state, never a crash",
       %{conn: conn} do
    Application.put_env(:kazi, :lease_map_source, Fixture)
    start_supervised!({Fixture, snapshot: CoordinationSource.build([], [], [])})

    {:ok, _view, html} = live(conn, ~p"/starmap?debug=1")

    assert html =~ ~s(id="mc-sessions-empty")
    assert html =~ "No sessions present"
  end
end

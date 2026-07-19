defmodule KaziWeb.RootLandingTest do
  @moduledoc """
  The root route serves Mission Control (ADR-0070): `/` is the fleet home page
  and `/starmap` remains an alias so existing links keep working.

  Asserts both the static (disconnected) render and the live (connected) mount
  on both routes.
  """
  use KaziWeb.ConnCase, async: false

  test "GET / renders the Mission Control shell (static render)", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ ~s(id="mission-control")
  end

  test "the root LiveView mounts and connects as Mission Control", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(id="mission-control")
    assert html =~ "KAZI"
  end

  test "/starmap stays as an alias for the same view", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/starmap")
    assert html =~ ~s(id="mission-control")
  end
end

defmodule KaziWeb.RootLandingTest do
  @moduledoc """
  The root route serves the fleet starmap (ADR-0057): `/` is the landing page
  and `/starmap` remains an alias so existing links and specs keep working.

  Asserts both the static (disconnected) render and the live (connected) mount
  on both routes.
  """
  use KaziWeb.ConnCase, async: false

  test "GET / renders the starmap shell (static render)", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ ~s(id="starmap")
  end

  test "the root LiveView mounts and connects as the starmap", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(id="starmap")
    assert html =~ ~s(id="starmap-rail")
  end

  test "/starmap stays as an alias for the same view", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/starmap")
    assert html =~ ~s(id="starmap")
  end
end

defmodule KaziWeb.DashboardLiveTest do
  @moduledoc """
  LiveView smoke test (T3.6a): the root LiveView mounts and renders its shell.

  Asserts both the static (disconnected) render and the live (connected) mount
  so T3.6b/c/d can build panels on a verified mount path.
  """
  use KaziWeb.ConnCase, async: true

  test "GET / renders the dashboard shell (static render)", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "kazi operator dashboard"
  end

  test "the root LiveView mounts and connects", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~s(id="dashboard")
    assert html =~ "kazi operator dashboard"
  end
end

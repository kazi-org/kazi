defmodule KaziWeb.LiveClientTest do
  @moduledoc """
  Pins the no-build LiveView client wiring (Mission Control's live poll-tick
  fleet refresh needs a connected socket):
  the hex packages' pre-built bundles serve from the endpoint's `Plug.Static`
  mounts, and the root layout carries the csrf-token meta plus the connect
  script. Without these, every dashboard page silently degrades to a
  read-only snapshot and no click interaction can ever fire.
  """
  use KaziWeb.ConnCase, async: false

  test "the phoenix and live_view client bundles are served", %{conn: conn} do
    for path <- [
          "/assets/phoenix/phoenix.min.js",
          "/assets/phoenix_live_view/phoenix_live_view.min.js"
        ] do
      response = get(conn, path)
      assert response.status == 200, "expected 200 for #{path}"
      assert response.resp_body =~ "LiveSocket" or response.resp_body =~ "Socket"
    end
  end

  test "the root layout wires the live socket: csrf meta + bundles + connect", %{conn: conn} do
    html = conn |> get("/starmap") |> html_response(200)

    assert html =~ ~s(name="csrf-token")
    assert html =~ ~s(src="/assets/phoenix/phoenix.min.js")
    assert html =~ ~s(src="/assets/phoenix_live_view/phoenix_live_view.min.js")
    assert html =~ "liveSocket.connect()"
  end
end

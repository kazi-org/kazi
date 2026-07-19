defmodule KaziWeb.HealthControllerTest do
  @moduledoc """
  Endpoint smoke test (T3.6a): the supervised endpoint serves `/healthz` 200.

  This is the ExUnit half of the acceptance bar — it proves the web tree boots
  under the supervision tree and the liveness route answers, without a browser.
  """
  use KaziWeb.ConnCase, async: true

  test "GET /healthz returns 200 ok", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert response(conn, 200) == "ok"
    assert response_content_type(conn, :text) =~ "text/plain"
  end
end

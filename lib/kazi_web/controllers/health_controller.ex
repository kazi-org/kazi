defmodule KaziWeb.HealthController do
  @moduledoc """
  Liveness probe for the dashboard endpoint (T3.6a).

  Returns a bare `200 ok`. The deploy/verify chain (and the Playwright smoke
  test) hit `/healthz` to confirm the supervised endpoint is serving traffic.
  It touches no read-model and no loop state — a dead-simple liveness signal.
  """
  use KaziWeb, :controller

  @doc "Respond 200 with a plain `ok` body."
  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end
end

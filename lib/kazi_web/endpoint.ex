defmodule KaziWeb.Endpoint do
  @moduledoc """
  The Phoenix endpoint for the operator dashboard (ADR-0011, T3.6a).

  Cowboy serves the plug pipeline; the LiveView socket carries the live
  dashboard. The endpoint is intentionally lean — no esbuild/tailwind asset
  tooling — because the dashboard is a read projection, not a full Phoenix app.
  The session is required by LiveView; its salts come from config.
  """
  use Phoenix.Endpoint, otp_app: :kazi

  # The session is stored in a signed (not encrypted) cookie. LiveView reuses it
  # to authenticate the socket; the salts/secret come from config (a fixed dev
  # value, a generated prod value at runtime).
  @session_options [
    store: :cookie,
    key: "_kazi_key",
    signing_salt: "kazi-dash",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(KaziWeb.Router)
end

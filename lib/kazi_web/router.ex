defmodule KaziWeb.Router do
  @moduledoc """
  Routes for the operator dashboard (ADR-0011, T3.6a).

  `/healthz` is a plain plug health probe (no session/LiveView) used by the
  deploy/verify chain and the Playwright smoke test. `/` is the root LiveView —
  the shell that T3.6b/c/d hang the goal board, presence/lease map, and history
  view onto.
  """
  use KaziWeb, :router

  # Browser-facing pages: session + LiveView need the session cookie and the
  # root layout. The pipeline is deliberately minimal (no CSRF-protected forms
  # yet — the skeleton is read-only).
  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {KaziWeb.Layouts, :root})
  end

  # Health probe: no session, no layout — a bare 200 for liveness checks.
  pipeline :health do
    plug(:accepts, ["html", "json"])
  end

  scope "/", KaziWeb do
    pipe_through(:health)

    get("/healthz", HealthController, :index)
  end

  scope "/", KaziWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end
end

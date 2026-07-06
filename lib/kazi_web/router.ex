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
    # T46.5: the fleet starmap — every registered `kazi apply` run at a glance
    # (ADR-0011 read projection of `Kazi.ReadModel.RunRegistry`, ADR-0057).
    live("/starmap", StarmapLive, :index)
    # T3.6b: the goal board — goals + status + predicate vector + iteration count,
    # live-updating from Kazi.ReadModel (ADR-0011 read projection).
    live("/goals", GoalBoardLive, :index)
    live("/leases", LeaseMapLive, :index)
    # T23.7: the live dependency-DAG dashboard — groups by running/ready/blocked/
    # converged state, the `needs` edges, and per-group convergence (ADR-0011
    # read projection of the dependency-graph scheduler, ADR-0028).
    live("/dag", DagLive, :index)
    live("/goals/:id/history", HistoryLive, :index)
    # T46.7: the drill-in convergence heatmap + iteration scrubber (ADR-0011
    # read projection of the per-iteration vector history, ADR-0057).
    live("/goals/:id/drillin", DrillinHeatmapLive, :index)
  end

  # Test-only seed/reset endpoints for the Playwright harness (T3.6b). Mounted
  # ONLY in the test env so the golden-path spec can seed the read-model and the
  # empty-state spec can clear it; never present in dev/prod. The controller lives
  # under test/support and is compiled only on the :test elixirc path.
  if Mix.env() == :test do
    scope "/test", KaziWeb do
      pipe_through(:health)

      post("/seed", TestSeedController, :seed)
      post("/reset", TestSeedController, :reset)
      # T3.6c: drive the lease-map fixture source (presence/intent/lease snapshot).
      post("/leases/seed", LeaseMapSeedController, :seed)
      post("/leases/release", LeaseMapSeedController, :release)
    end
  end
end

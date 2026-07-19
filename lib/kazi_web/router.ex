defmodule KaziWeb.Router do
  @moduledoc """
  Routes for the operator dashboard (ADR-0011, T3.6a).

  `/healthz` is a plain plug health probe (no session/LiveView) used by the
  deploy/verify chain and the Playwright smoke test. `/` is Mission Control
  (ADR-0070) — the fleet home page; the goal board, lease map, DAG, and history
  views hang off their own routes.
  """
  use KaziWeb, :router

  # Browser-facing pages: session + LiveView need the session cookie and the
  # root layout. CSRF protection seeds the session token the LiveView socket
  # connect verifies (the layout's csrf-token meta + `_csrf_token` param) —
  # required for the live client, harmless for the GET-only pages.
  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {KaziWeb.Layouts, :root})
  end

  # Health probe: no session, no layout — a bare 200 for liveness checks.
  pipeline :health do
    plug(:accepts, ["html", "json"])
  end

  # JSON API for a personal dashboard doing a bare fetch() (issue #1077): no
  # session/CSRF, matching :health's pattern rather than :browser's — a
  # stateless GET must not need a cookie dance.
  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", KaziWeb do
    pipe_through(:health)

    get("/healthz", HealthController, :index)
  end

  scope "/api", KaziWeb.API do
    pipe_through(:api)

    get("/runs", RunsController, :index)
    get("/goals", GoalsController, :index)
  end

  scope "/", KaziWeb do
    pipe_through(:browser)

    # Mission Control is the landing page — every registered `kazi apply` run at
    # a glance as an ops-center card grid (ADR-0011 read projection of
    # `Kazi.ReadModel.RunRegistry`, ADR-0070, superseding the ADR-0057 starmap
    # home view). `/starmap` stays as an alias for existing links.
    live("/", MissionControlLive, :index)
    live("/starmap", MissionControlLive, :index)
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
    # T46.8: the transcript peek -- tails a run's transcript.jsonl, live or
    # post-mortem, the same code path either way (ADR-0011, ADR-0057).
    live("/runs/:run_id/transcript", TranscriptPeekLive, :index)
    # T47.1: the event river -- fleet-wide feed of every run's events.jsonl,
    # newest first (ADR-0011 read projection, ADR-0057).
    live("/events", EventRiverLive, :index)
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
      # T63.6: seed/clear the run registry for the Mission Control direction-B
      # fleet-grid cert (project-grouped cards + segmented header filters).
      post("/fleet/seed", TestSeedController, :seed_fleet)
      post("/fleet/seed_single", TestSeedController, :seed_fleet_single)
      # T63.9: seed an active goal with iterations + budget for the progress-rate panel.
      post("/fleet/seed_progress", TestSeedController, :seed_progress)
      post("/fleet/reset", TestSeedController, :reset_fleet)
      # T63.8: seed/clear the attention fan-in (a run-attention alert + a
      # waiting-on-operator session) for the browser cert.
      post("/attention/seed", TestSeedController, :seed_attention)
      post("/attention/reset", TestSeedController, :reset_attention)
      # T3.6c: drive the lease-map fixture source (presence/intent/lease snapshot).
      post("/leases/seed", LeaseMapSeedController, :seed)
      post("/leases/release", LeaseMapSeedController, :release)
    end
  end
end

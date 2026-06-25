defmodule KaziWeb.DagSource do
  @moduledoc """
  The injectable read seam the live dependency-DAG dashboard renders from
  (T23.7, UC-038, ADR-0011 / ADR-0028).

  The DAG dashboard is a pure READ projection of a `needs`-DAG run: which groups
  are running / ready / blocked / converged, the `needs` edges between them, and
  per-group convergence. That state lives in the `Kazi.Scheduler.DepScheduler`'s
  process, which broadcasts a render-ready `Kazi.Scheduler.DagSnapshot` on
  `Kazi.Scheduler.DagSnapshot.topic/0` as the run progresses. The LiveView never
  reaches into the scheduler — it asks a *source* for the current `%DagSnapshot{}`
  and subscribes to that source's topic for live pushes. This is the ADR-0011 §3
  injection seam: production points it at `KaziWeb.DagSource` (this module),
  which serves the last broadcast snapshot from a small cache; a LiveView test
  points it at a fixture source that holds a snapshot in memory and pushes
  updates on demand — so the surface certifies with no scheduler and no harness.

  ## The contract

    * `snapshot/0` returns the current `%DagSnapshot{}` — the live DAG, or
      `DagSnapshot.empty/0` when no run is active (an honest "no active run"
      state, never fabricated sample nodes).
    * `topic/0` names the `Kazi.PubSub` topic the source broadcasts on. The view
      subscribes on its connected mount; a `{:dag_updated, snapshot}` broadcast
      re-renders.

  The default implementation serves the latest snapshot held by
  `KaziWeb.DagSource.Cache` (which subscribes to the scheduler's broadcast topic
  and remembers the last frame, so a mid-run mount shows current state) and
  exposes the scheduler's broadcast topic directly, so a view subscribed to it
  receives the scheduler's live pushes unchanged.
  """

  @behaviour __MODULE__

  alias Kazi.Scheduler.DagSnapshot
  alias KaziWeb.DagSource.Cache

  @doc "The current DAG snapshot — the live run, or `DagSnapshot.empty/0`."
  @callback snapshot() :: DagSnapshot.t()

  @doc "The `Kazi.PubSub` topic this source broadcasts `{:dag_updated, snapshot}` on."
  @callback topic() :: String.t()

  @impl __MODULE__
  def snapshot, do: Cache.current()

  @impl __MODULE__
  def topic, do: DagSnapshot.topic()
end

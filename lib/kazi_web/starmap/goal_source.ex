defmodule KaziWeb.Starmap.GoalSource do
  @moduledoc """
  The injectable read seam Mission Control's roadmap wave grouping renders
  from (ADR-0070, preserving T47.2, extending ADR-0056's roadmap-DAG concept).

  Mission Control's home view is a fleet-wide projection of the run registry;
  roadmap grouping ADDITIONALLY overlays that fleet onto a `needs`-DAG so the
  fleet cards group into topological WAVE SECTIONS (reusing
  `Kazi.Goal.DepGraph.frontiers/1`, the same computation `kazi apply --explain`
  prints) instead of a flat grid. That DAG is:

    * the **ADR-0056 roadmap DAG** — a goal whose declared groups are the
      roadmap's goal-level `needs` edges — when a roadmap ref has been
      configured (`kazi plan --project`'s eventual output; not yet a
      first-class read-model object), or
    * **absent**, in which case Mission Control falls back to "single-goal
      groups": a flat grid of the currently registered runs with no declared
      ordering, exactly the walking-skeleton behavior the first fleet slice
      shipped.

  This module is the ADR-0011 §3 injection point (mirroring
  `KaziWeb.DagSource`/`KaziWeb.CoordinationSource`): production defaults to
  `KaziWeb.Starmap.GoalSource.None` (no roadmap configured — always the flat
  fallback); a test points `Application.put_env(:kazi, :starmap_goal_source,
  ...)` at a fixture module returning a seeded `Kazi.Goal.t()` so the
  wave-band layout certifies with no scheduler, no CLI, and no goal-file on
  disk.
  """

  alias Kazi.Goal

  @doc "The roadmap goal to lay out in wave bands, or `nil` for the flat fallback."
  @callback goal() :: Goal.t() | nil

  @doc "The currently configured source (default: `None`, i.e. no roadmap)."
  @spec source() :: module()
  def source, do: Application.get_env(:kazi, :starmap_goal_source, __MODULE__.None)

  @doc "The current roadmap goal from the configured source, or `nil`."
  @spec goal() :: Goal.t() | nil
  def goal, do: source().goal()

  defmodule None do
    @moduledoc "The default `GoalSource`: no roadmap configured, always `nil`."
    @behaviour KaziWeb.Starmap.GoalSource

    @impl true
    def goal, do: nil
  end

  defmodule Static do
    @moduledoc """
    The `GoalSource` `kazi dashboard --roadmap <goal-file>` configures (T47.2):
    returns whatever `Kazi.Goal.t()` was loaded at boot and stashed in
    application env (`:kazi, :starmap_roadmap_goal`) — the same cross-process
    seam the wave-band tests' stub source uses, since application env (unlike
    the process dictionary) is visible from the LiveView's own process.
    """
    @behaviour KaziWeb.Starmap.GoalSource

    @impl true
    def goal, do: Application.get_env(:kazi, :starmap_roadmap_goal)
  end
end

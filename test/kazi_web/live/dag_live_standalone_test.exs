defmodule KaziWeb.DagLiveStandaloneTest do
  @moduledoc """
  Regression checker for GitHub issue #801: `kazi dashboard` (the standalone
  fleet-mode boot, T46.4/ADR-0057) 500s on `/dag` when no `apply --parallel`
  run is active, because `KaziWeb.DagSource.Cache` is supervised only by the
  full app tree (`Kazi.Application`), not by the standalone dashboard
  supervisor (`Kazi.CLI.start_standalone_endpoint/2`).

  Two contracts, both required:

    1. **Graceful degradation** — `/dag` renders (200, the honest "No active
       run" empty state) even when the DAG snapshot cache process is not
       alive. This is the exact crash path from the issue's log:
       `GenServer.call(KaziWeb.DagSource.Cache, :current, 5000)` → `:noproc`
       → 500. A supervised process can still be down mid-restart, so the read
       path must not assume it.

    2. **Standalone tree parity** — `Kazi.CLI.standalone_dashboard_children/0`
       (a public seam, matching the codebase's injectable-seam idiom) returns
       the child specs a FRESH `kazi dashboard` boot supervises, in start
       order, and that list mirrors the app web tree's composition:
       Phoenix.PubSub, then Kazi.Coordination.LeaseTable, then
       KaziWeb.DagSource.Cache, then KaziWeb.Endpoint. PubSub must precede
       the cache (the cache subscribes on init); the endpoint must come last
       (it serves reads from all of them). The boot path may filter children
       whose singleton process is already running in this node.

  This file is a READ-ONLY acceptance checker for the kazi goal driving the
  fix (ADR-0042): the implementation must satisfy it, never edit it.
  """
  use KaziWeb.ConnCase, async: false

  describe "contract 1: /dag degrades gracefully when the cache is down (issue #801)" do
    test "GET /dag renders the empty state, not a 500, with DagSource.Cache not alive",
         %{conn: conn} do
      # Simulate the standalone-boot world of v1.73.3: the cache process is
      # absent. terminate_child (not kill) so the one_for_one supervisor does
      # not restart it mid-request; restore it for the rest of the suite.
      :ok = Supervisor.terminate_child(Kazi.Supervisor, KaziWeb.DagSource.Cache)

      on_exit(fn ->
        Supervisor.restart_child(Kazi.Supervisor, KaziWeb.DagSource.Cache)
      end)

      refute Process.whereis(KaziWeb.DagSource.Cache)

      html = conn |> get("/dag") |> html_response(200)
      assert html =~ "No active run"
    end
  end

  describe "contract 2: the standalone dashboard tree has web-tree parity" do
    test "standalone_dashboard_children/0 lists PubSub, LeaseTable, the cache, then the endpoint" do
      children = Kazi.CLI.standalone_dashboard_children()

      index = fn matcher -> Enum.find_index(children, matcher) end

      pubsub =
        index.(fn
          {Phoenix.PubSub, _} -> true
          Phoenix.PubSub -> true
          _ -> false
        end)

      lease_table =
        index.(fn
          Kazi.Coordination.LeaseTable -> true
          {Kazi.Coordination.LeaseTable, _} -> true
          _ -> false
        end)

      cache =
        index.(fn
          KaziWeb.DagSource.Cache -> true
          {KaziWeb.DagSource.Cache, _} -> true
          _ -> false
        end)

      endpoint =
        index.(fn
          KaziWeb.Endpoint -> true
          {KaziWeb.Endpoint, _} -> true
          _ -> false
        end)

      assert pubsub, "standalone children must include Phoenix.PubSub"
      assert lease_table, "standalone children must include Kazi.Coordination.LeaseTable"
      assert cache, "standalone children must include KaziWeb.DagSource.Cache (issue #801)"
      assert endpoint, "standalone children must include KaziWeb.Endpoint"

      assert pubsub < cache, "PubSub must start before the cache (it subscribes on init)"
      assert cache < endpoint, "the cache must start before the endpoint that reads it"
      assert lease_table < endpoint, "the lease table must start before the endpoint"
    end
  end
end

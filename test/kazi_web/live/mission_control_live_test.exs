defmodule KaziWeb.MissionControlLiveTest do
  @moduledoc """
  LiveView test for the Mission Control fleet home view (UC-061, ADR-0070,
  superseding the ADR-0057 starmap home view).

  Seeds the (sandbox-isolated) run registry and per-goal iteration history
  directly — no scheduler, no real `kazi apply` process — and asserts the view
  renders the empty state with no runs, maps each registry fact to its display
  state (running / converged / stuck / stale / over-budget), renders the
  per-card predicate DNA + burn from the read-model history, sums the fleet
  chips over the shown cards, surfaces the attention queue as alert cards, and
  reflects a status change on the next poll tick without a restart. Hermetic:
  the read-model IS the fixture source.
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.{PredicateResult, PredicateVector, ReadModel}
  alias Kazi.ReadModel.{ProposedGoal, Run, RunRegistry}
  alias Kazi.Repo

  defp seed_proposal(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          proposal_ref: "prop-todo-#{System.unique_integer([:positive])}",
          goal_id: "todo-goal-#{System.unique_integer([:positive])}",
          idea: "an approved but undispatched goal",
          status: "approved"
        },
        overrides
      )

    Repo.insert!(struct(ProposedGoal, attrs))
  end

  defp seed(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          run_id: "run-#{System.unique_integer([:positive])}",
          pid: "#PID<0.1.0>",
          workspace: "/tmp/ws/kazi-repo",
          goal_ref: "goal-#{System.unique_integer([:positive])}",
          harness: "claude",
          model: "claude-sonnet-5",
          session_os_pid: "424242"
        },
        overrides
      )

    {:ok, run} = RunRegistry.start(attrs)
    run
  end

  defp age_heartbeat(run, seconds_ago) do
    run
    |> Run.changeset(%{"heartbeat_at" => DateTime.add(DateTime.utc_now(), -seconds_ago, :second)})
    |> Repo.update!()
  end

  defp record(goal_ref, index, vector, opts \\ []) do
    {:ok, iteration} =
      ReadModel.record_iteration(
        Keyword.merge(
          [goal_ref: goal_ref, iteration_index: index, predicate_vector: vector],
          opts
        )
        |> Map.new()
      )

    iteration
  end

  defp vector(unit_status, probe_status) do
    PredicateVector.new(%{
      unit: PredicateResult.new(unit_status, %{exit: 0}),
      probe: PredicateResult.new(probe_status, %{http_status: 200})
    })
  end

  test "renders the empty state with no registered runs", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="mission-control")
    assert html =~ ~s(id="mission-control-empty")
    refute html =~ ~s(id="mc-fleet") <> ~s( class="grid")
  end

  test "/starmap stays as an alias for the same view", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/starmap")
    assert html =~ ~s(id="mission-control")
  end

  test "a converged terminal run renders as a CONVERGED card", %{conn: conn} do
    run = seed(%{goal_ref: "ship-it"})
    {:ok, _} = RunRegistry.finish(run.run_id, "converged")

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="mc-card-ship-it")
    assert html =~ ~s(data-state="landed")
    assert html =~ "CONVERGED"
  end

  test "a stuck terminal run renders as a STUCK alarm card", %{conn: conn} do
    run = seed(%{goal_ref: "wedged"})
    {:ok, _} = RunRegistry.finish(run.run_id, "stuck")

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="mc-card-wedged")
    assert html =~ ~r/id="mc-card-wedged"[^>]*data-state="stuck"/
    # The lone card carries the red-alarm frame.
    assert html =~ ~s(class="card c-bad")
  end

  test "an over-budget run splits into its own fleet chip but still alarms", %{conn: conn} do
    run = seed(%{goal_ref: "spendy"})
    {:ok, _} = RunRegistry.finish(run.run_id, "over_budget")

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(data-state="stuck")
    assert html =~ "OVER-BUDGET"
    # The over-budget chip counts 1; the plain STUCK chip does not double-count it.
    assert html =~ ~r/class="dot da"><\/span>1 OVER-BUDGET/
    assert html =~ ~r/class="dot dr"><\/span>0 STUCK/
  end

  test "a fresh-heartbeat running run renders as a RUNNING card", %{conn: conn} do
    seed(%{goal_ref: "in-flight"})

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="mc-card-in-flight")
    assert html =~ ~s(data-state="converging")
    assert html =~ "RUNNING"
  end

  test "a running run with a stale heartbeat renders as a STALE card", %{conn: conn} do
    run = seed(%{goal_ref: "hung"})
    age_heartbeat(run, 200)

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="mc-card-hung")
    assert html =~ ~s(data-state="stale")
    assert html =~ "STALE"
  end

  test "harness/model badge, workspace basename, and fleet chip counts render", %{conn: conn} do
    seed(%{goal_ref: "a", harness: "codex", model: "gpt-5", workspace: "/tmp/ws/site-repo"})
    seed(%{goal_ref: "b", harness: "codex", model: "gpt-5"})
    run = seed(%{goal_ref: "c", harness: "codex", model: "gpt-5"})
    {:ok, _} = RunRegistry.finish(run.run_id, "converged")

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "codex · gpt-5"
    assert html =~ "site-repo"
    assert html =~ ~r/class="dot dg"><\/span>2 RUNNING/
    assert html =~ ~r/class="dot dgg"><\/span>1 CONVERGED/
    assert html =~ "FLEET · 3 LIVE"
    assert html =~ "CURRENT · 3"
  end

  test "the predicate DNA strip renders the latest iteration's vector as squares", %{conn: conn} do
    seed(%{goal_ref: "dna-goal"})
    record("dna-goal", 0, vector(:fail, :fail))
    record("dna-goal", 1, vector(:pass, :fail))

    {:ok, _view, html} = live(conn, ~p"/")

    # Latest iteration (index 1): unit pass (dg), probe fail (dr).
    assert html =~ ~s(<span class="dna dg"></span>)
    assert html =~ ~s(<span class="dna dr"></span>)
    assert html =~ "ITER 1"
  end

  test "the burn bar reads the declared iteration budget", %{conn: conn} do
    seed(%{goal_ref: "budget-goal", max_iterations: 4})
    record("budget-goal", 3, vector(:pass, :fail))

    {:ok, _view, html} = live(conn, ~p"/")

    # iter 4 / 4 == 100% -> the hot burn class.
    assert html =~ "iter 4 / 4"
    assert html =~ ~s(class="burnfill b-hot")
  end

  test "a stuck run surfaces as a NEEDS ATTENTION alert card", %{conn: conn} do
    run = seed(%{goal_ref: "needs-me"})
    # A stuck detector needs a red predicate across iterations.
    record("needs-me", 0, vector(:fail, :pass))
    record("needs-me", 1, vector(:fail, :pass))
    record("needs-me", 2, vector(:fail, :pass))
    {:ok, _} = RunRegistry.finish(run.run_id, "stuck")

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="mc-attention")
    assert html =~ "NEEDS ATTENTION"
    assert html =~ ~s(data-goal-ref="needs-me")
    assert html =~ "PEEK →"
  end

  test "the event river renders its empty state with no events", %{conn: conn} do
    seed()

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="mission-control-river-empty")
    assert html =~ "EVENT RIVER"
  end

  test "a status change is reflected on the next poll tick without a restart", %{conn: conn} do
    run = seed(%{goal_ref: "flipper"})

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ ~s(data-state="converging")

    {:ok, _} = RunRegistry.finish(run.run_id, "converged")

    send(view.pid, :tick)
    html = render(view)

    assert html =~ ~s(id="mc-card-flipper")
    assert html =~ ~s(data-state="landed")
  end

  test "cards and alerts deep-link into the goal's full drill-in view", %{conn: conn} do
    seed(%{goal_ref: "linky"})

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(href="/goals/linky/drillin")
  end

  test "the CURRENT/CLOSED toggle scopes the grid to live vs closed sessions", %{conn: conn} do
    # The liveness stub treats a "dead-*" session pid as a closed session.
    seed(%{goal_ref: "live-one", session_os_pid: "424242"})
    closed = seed(%{goal_ref: "closed-one", session_os_pid: "dead-9"})
    {:ok, _} = RunRegistry.finish(closed.run_id, "converged")

    {:ok, view, html} = live(conn, ~p"/")

    # CURRENT (default): the live-session run shows; the closed one does not.
    assert html =~ ~s(id="mc-card-live-one")
    refute html =~ ~s(id="mc-card-closed-one")
    assert html =~ "CURRENT · 1"
    assert html =~ "CLOSED · 1"

    # Flip to CLOSED: the dead-session run shows, the live one drops out.
    html = view |> element(~s(button[phx-value-scope="closed"])) |> render_click()

    assert html =~ ~s(id="mc-card-closed-one")
    refute html =~ ~s(id="mc-card-live-one")
    assert html =~ ~s(data-scope="closed")
  end

  test "an empty CURRENT grid with closed history points at the CLOSED toggle", %{conn: conn} do
    closed = seed(%{goal_ref: "only-closed", session_os_pid: "dead-1"})
    {:ok, _} = RunRegistry.finish(closed.run_id, "stuck")

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="mission-control-empty")
    assert html =~ "No live runs right now"
    assert html =~ "1 closed"
  end

  describe "filters and card provenance" do
    test "a card shows its project, age, and last-active", %{conn: conn} do
      run = seed(%{goal_ref: "prov", workspace: "/tmp/ws/kazi-repo"})
      age_heartbeat(run, 300)

      {:ok, _view, html} = live(conn, ~p"/")

      # Workspace has no git remote, so the project falls back to the last two
      # path segments — still the grouping key the repo dropdown uses.
      assert html =~ ~s(data-project="ws/kazi-repo")
      assert html =~ ~r/AGE \d+[smhd]/
      assert html =~ "ACTIVE 5m ago"
    end

    test "clicking a fleet chip filters to that state; clicking again clears", %{conn: conn} do
      seed(%{goal_ref: "live-one"})
      done = seed(%{goal_ref: "done-one"})
      {:ok, _} = RunRegistry.finish(done.run_id, "converged")

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ ~s(id="mc-card-live-one")
      assert html =~ ~s(id="mc-card-done-one")

      html = view |> element(~s(button[data-count="converged"])) |> render_click()
      assert html =~ ~s(id="mc-card-done-one")
      refute html =~ ~s(id="mc-card-live-one")

      html = view |> element(~s(button[data-count="converged"])) |> render_click()
      assert html =~ ~s(id="mc-card-live-one")
      assert html =~ ~s(id="mc-card-done-one")
    end

    test "the repo dropdown filters cards to one project", %{conn: conn} do
      seed(%{goal_ref: "in-a", workspace: "/tmp/org-a/repo-a"})
      seed(%{goal_ref: "in-b", workspace: "/tmp/org-b/repo-b"})

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ ~s(id="mc-card-in-a")
      assert html =~ ~s(id="mc-card-in-b")

      html =
        view
        |> element("#mc-filters")
        |> render_change(%{"repo" => "org-a/repo-a", "window" => ""})

      assert html =~ ~s(id="mc-card-in-a")
      refute html =~ ~s(id="mc-card-in-b")

      html =
        view |> element("#mc-filters") |> render_change(%{"repo" => "", "window" => ""})

      assert html =~ ~s(id="mc-card-in-b")
    end

    test "the time window filters out runs last active before the cutoff", %{conn: conn} do
      seed(%{goal_ref: "fresh-run"})
      seed(%{goal_ref: "old-run"}) |> age_heartbeat(2 * 3_600)

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ ~s(id="mc-card-old-run")

      html =
        view |> element("#mc-filters") |> render_change(%{"repo" => "", "window" => "1h"})

      assert html =~ ~s(id="mc-card-fresh-run")
      refute html =~ ~s(id="mc-card-old-run")
    end

    test "a state filter that hides everything renders the filtered empty state", %{conn: conn} do
      seed(%{goal_ref: "only-running"})

      {:ok, view, _html} = live(conn, ~p"/")
      html = view |> element(~s(button[data-count="converged"])) |> render_click()

      assert html =~ ~s(id="mission-control-filtered-empty")
      refute html =~ ~s(id="mc-card-only-running")
    end
  end

  describe "cross-machine fleet visibility (T60.1, #1154)" do
    defp with_remote_facts(facts) do
      Application.put_env(:kazi, :remote_run_facts_fetcher, fn -> facts end)
      on_exit(fn -> Application.delete_env(:kazi, :remote_run_facts_fetcher) end)
    end

    defp remote_fact(topic, machine, text) do
      %{"topic" => topic, "machine" => machine, "text" => text}
    end

    test "a run in flight on another machine renders as a distinct remote card", %{conn: conn} do
      with_remote_facts([
        remote_fact("run:abcdef12", "mini", "iter 3: 2/5 passing remote-goal")
      ])

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(id="mc-card-remote-goal")
      assert html =~ ~s(data-remote="true")
      assert html =~ "remote · mini"
    end

    test "a fact from THIS machine is never rendered as remote (self-exclusion)", %{conn: conn} do
      with_remote_facts([
        remote_fact("run:abcdef12", Kazi.Bus.hostname(), "started local-goal-not-registered")
      ])

      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ ~s(id="mc-card-local-goal-not-registered")
    end

    test "a remote fact for a goal ALSO present in the local registry is not duplicated", %{
      conn: conn
    } do
      seed(%{goal_ref: "shared-goal"})
      with_remote_facts([remote_fact("run:abcdef12", "mini", "started shared-goal")])

      {:ok, _view, html} = live(conn, ~p"/")

      assert length(:binary.matches(html, ~s(id="mc-card-shared-goal"))) == 1
    end

    test "converged/stuck/terminated remote facts map to the right state", %{conn: conn} do
      with_remote_facts([
        remote_fact("run:11111111", "mini", "converged goal-a (3/3 passing, 2 iters)"),
        remote_fact("run:22222222", "mini", "stuck goal-b (1/3 passing, 5 iters)"),
        remote_fact("run:33333333", "mini", "terminated goal-c (killed)")
      ])

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(id="mc-card-goal-a" class="card c-ok remote")
      assert html =~ ~s(id="mc-card-goal-b" class="card c-bad remote")
      assert html =~ ~s(id="mc-card-goal-c" class="card c-bad remote")
    end

    test "a bus board fetch failure degrades to zero remote cards, never an error", %{conn: conn} do
      Application.put_env(:kazi, :remote_run_facts_fetcher, fn -> raise "no daemon" end)
      on_exit(fn -> Application.delete_env(:kazi, :remote_run_facts_fetcher) end)

      seed(%{goal_ref: "local-only"})
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(id="mc-card-local-only")
    end
  end

  describe "PLANNED section (T60.4, #1160)" do
    test "approved undispatched proposals render as todo cards", %{conn: conn} do
      p = seed_proposal()
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "mc-planned-#{p.proposal_ref}"
      assert html =~ "PLANNED"
      assert html =~ p.goal_id
      assert html =~ "TODO"
    end

    test "a proposal whose goal has ANY registered run leaves PLANNED", %{conn: conn} do
      p = seed_proposal()
      seed(%{goal_ref: p.goal_id})
      {:ok, _view, html} = live(conn, "/")

      refute html =~ "mc-planned-#{p.proposal_ref}"
    end

    test "proposed and rejected proposals do not render; no approved -> no section", %{conn: conn} do
      seed_proposal(%{status: "proposed"})
      seed_proposal(%{status: "rejected"})
      {:ok, _view, html} = live(conn, "/")

      refute html =~ "id=\"mc-planned"
    end
  end
end

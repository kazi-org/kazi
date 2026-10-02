defmodule KaziWeb.StuckEscalationPanelTest do
  @moduledoc """
  LiveView test for the stuck-escalation panel component (T48.14).

  The stuck-escalation panel surfaces terminal causes that require human
  intervention in stuck runs, ranked by severity. Tests verify that:
  - Stuck runs with terminal causes (error_wedged, quarantine_blocked) are
    surfaced and ranked above ordinary stuck runs
  - The cause detail and drill-in links are correctly rendered
  - Hermetic: the read-model IS the fixture source
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.{PredicateResult, PredicateVector}
  alias Kazi.ReadModel
  alias Kazi.ReadModel.RunRegistry

  setup do
    for key <- [:remote_run_facts_fetcher, :waiting_sessions_fetcher] do
      previous = Application.fetch_env(:kazi, key)
      Application.put_env(:kazi, key, fn -> [] end)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:kazi, key, value)
          :error -> Application.delete_env(:kazi, key)
        end
      end)
    end

    :ok
  end

  defp seed(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          run_id: "run-#{System.unique_integer([:positive])}",
          pid: "#PID<0.1.0>",
          workspace: "/tmp/ws",
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

  defp record(goal_ref, index, vector) do
    {:ok, _} =
      ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: index,
        predicate_vector: vector
      })
  end

  test "a stuck run with error_wedged cause surfaces the panel with cause detail",
       %{conn: conn} do
    run = seed()

    {:ok, _} =
      RunRegistry.finish(run.run_id, "stuck", %{
        outcome_cause_class: "error_wedged",
        outcome_cause_detail: %{
          "ids" => ["live_route"],
          "reasons" => %{"live_route" => "missing_url"},
          "exhausted" => nil
        }
      })

    {:ok, view, html} = live(conn, ~p"/starmap")

    assert has_element?(
             view,
             ~s(#mc-alert-#{run.goal_ref}-cause[href="/goals/#{run.goal_ref}/drillin"]),
             "error_wedged (live_route: missing_url)"
           )

    assert html =~ ~s(href="/goals/#{run.goal_ref}/drillin")
  end

  test "a stuck run with quarantine_blocked cause surfaces the panel with cause detail",
       %{conn: conn} do
    run = seed()

    {:ok, _} =
      RunRegistry.finish(run.run_id, "stuck", %{
        outcome_cause_class: "quarantine_blocked",
        outcome_cause_detail: %{"ids" => ["flappy"], "reasons" => %{}, "exhausted" => nil}
      })

    {:ok, view, html} = live(conn, ~p"/starmap")

    assert has_element?(
             view,
             ~s(#mc-alert-#{run.goal_ref}-cause[href="/goals/#{run.goal_ref}/drillin"]),
             "quarantine_blocked (flappy)"
           )

    assert html =~ ~s(href="/goals/#{run.goal_ref}/drillin")
  end

  test "cause-ranked entries precede ordinary stuck runs in the attention queue",
       %{conn: conn} do
    wedged = seed()

    {:ok, _} =
      RunRegistry.finish(wedged.run_id, "stuck", %{
        outcome_cause_class: "error_wedged",
        outcome_cause_detail: %{
          "ids" => ["live_route"],
          "reasons" => %{"live_route" => "missing_url"},
          "exhausted" => nil
        }
      })

    stuck = seed()

    for index <- 0..2 do
      record(stuck.goal_ref, index, PredicateVector.new(%{"unit" => PredicateResult.fail()}))
    end

    {:ok, _view, html} = live(conn, ~p"/starmap")

    {cause_pos, _} = :binary.match(html, ~s(id="mc-alert-#{wedged.goal_ref}-cause"))
    {stuck_pos, _} = :binary.match(html, ~s(id="mc-alert-#{stuck.goal_ref}-stuck"))
    assert cause_pos < stuck_pos
  end

  test "budget exhaustion stays a budget alert without a needs-human cause", %{conn: conn} do
    run = seed(%{max_iterations: 1})
    record(run.goal_ref, 0, PredicateVector.new(%{"unit" => PredicateResult.fail()}))

    {:ok, _} =
      RunRegistry.finish(run.run_id, "over_budget", %{
        outcome_cause_class: "budget_exhausted",
        outcome_cause_detail: %{"ids" => [], "reasons" => %{}, "exhausted" => "max_iterations"}
      })

    {:ok, view, _html} = live(conn, ~p"/starmap")
    assert has_element?(view, "#mc-alert-#{run.goal_ref}-budget")
    refute has_element?(view, "#mc-alert-#{run.goal_ref}-cause")
  end
end

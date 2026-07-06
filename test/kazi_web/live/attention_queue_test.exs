defmodule KaziWeb.AttentionQueueTest do
  @moduledoc """
  LiveView test for the starmap's attention-queue rail (T46.6, UC-061,
  ADR-0057).

  Seeds the (sandbox-isolated) run registry + read-model directly — no
  scheduler, no real `kazi apply` process — and asserts the fleet-wide
  ranking (`Kazi.Attention.Queue`) each signal produces renders in the
  starmap's rail with a deep link to that goal's drill-in. Hermetic: the
  read-model IS the fixture source, exactly like `KaziWeb.StarmapLiveTest`.
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.{PredicateResult, PredicateVector}
  alias Kazi.ReadModel
  alias Kazi.ReadModel.RunRegistry

  defp seed(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          run_id: "run-#{System.unique_integer([:positive])}",
          pid: "#PID<0.1.0>",
          workspace: "/tmp/ws",
          goal_ref: "goal-#{System.unique_integer([:positive])}",
          harness: "claude",
          model: "claude-sonnet-5"
        },
        overrides
      )

    {:ok, run} = RunRegistry.start(attrs)
    run
  end

  defp record(goal_ref, index, vector, extra \\ %{}) do
    {:ok, _} =
      ReadModel.record_iteration(
        Map.merge(%{goal_ref: goal_ref, iteration_index: index, predicate_vector: vector}, extra)
      )
  end

  test "an empty fleet renders no attention queue", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/starmap")

    refute html =~ ~s(id="attention-queue")
  end

  test "a stuck run surfaces a ranked :stuck entry with a drill-in deep link", %{conn: conn} do
    run = seed()

    for index <- 0..2 do
      record(run.goal_ref, index, PredicateVector.new(%{"unit" => PredicateResult.fail()}))
    end

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(id="attention-item-#{run.goal_ref}-stuck")
    assert html =~ ~s(data-signal="stuck")
    assert html =~ ~s(data-predicate-id="unit")
    assert html =~ ~s(href="/goals/#{run.goal_ref}/drillin")
  end

  test "a run over 85% of its declared budget surfaces a :budget entry", %{conn: conn} do
    run = seed(%{max_iterations: 10})

    for index <- 0..8 do
      record(run.goal_ref, index, PredicateVector.new(%{"unit" => PredicateResult.pass()}))
    end

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(id="attention-item-#{run.goal_ref}-budget")
    assert html =~ ~s(data-signal="budget")
  end

  test "a recovered regression surfaces a :regression_recovered entry", %{conn: conn} do
    run = seed()

    record(run.goal_ref, 0, PredicateVector.new(%{"unit" => PredicateResult.pass()}))

    flag = %{
      predicate_id: :unit,
      green_iteration: 0,
      red_iteration: 1,
      status: :fail,
      attributed_dispatch: nil
    }

    record(run.goal_ref, 1, PredicateVector.new(%{"unit" => PredicateResult.fail()}), %{
      regressions: [flag]
    })

    record(run.goal_ref, 2, PredicateVector.new(%{"unit" => PredicateResult.pass()}))

    {:ok, _view, html} = live(conn, ~p"/starmap")

    assert html =~ ~s(id="attention-item-#{run.goal_ref}-regression_recovered")
    assert html =~ ~s(data-signal="regression_recovered")
  end

  test "a plain converging run with no signal renders the queue's empty state", %{conn: conn} do
    seed()

    {:ok, _view, html} = live(conn, ~p"/starmap")

    refute html =~ ~s(id="attention-queue")
    assert html =~ ~s(id="attention-queue-empty")
  end

  test "the queue reflects a newly stuck run on the next poll tick", %{conn: conn} do
    run = seed()

    {:ok, view, html} = live(conn, ~p"/starmap")
    refute html =~ ~s(id="attention-queue")

    for index <- 0..2 do
      record(run.goal_ref, index, PredicateVector.new(%{"unit" => PredicateResult.fail()}))
    end

    send(view.pid, :tick)
    html = render(view)

    assert html =~ ~s(id="attention-item-#{run.goal_ref}-stuck")
  end
end

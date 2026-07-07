defmodule KaziWeb.StarmapPanelTest do
  @moduledoc """
  LiveView test for the starmap's slide-over drill-in panel
  (docs/dashboard-design.md "Slide-over drill-in panel", ADR-0057).

  Clicking a canvas node (or an attention entry) opens a right slide-over
  peeking that goal without leaving the starmap: identity chips, the
  iteration/budget burn bar, the predicate-vector DNA strip, the convergence
  heatmap, and the transcript tail — the SAME read paths the full-page views
  use (`Kazi.ReadModel` iteration history, `Kazi.Sink.Transcript`), plus a
  "FULL ANALYST VIEW" link to the drill-in page. Hermetic: the sandboxed
  read-model IS the fixture source; the transcript is a tmp `.jsonl`.
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.{PredicateResult, PredicateVector, ReadModel}
  alias Kazi.ReadModel.RunRegistry

  defp seed(goal_ref, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          run_id: "run-#{System.unique_integer([:positive])}",
          pid: "#PID<0.1.0>",
          workspace: "/tmp/ws",
          goal_ref: goal_ref,
          harness: "claude",
          model: "claude-sonnet-5"
        },
        overrides
      )

    {:ok, run} = RunRegistry.start(attrs)
    run
  end

  defp record(goal_ref, index, vector) do
    {:ok, iteration} =
      ReadModel.record_iteration(%{
        goal_ref: goal_ref,
        iteration_index: index,
        predicate_vector: vector
      })

    iteration
  end

  defp vector(unit_status, probe_status) do
    PredicateVector.new(%{
      unit: PredicateResult.new(unit_status, %{exit: 0}),
      probe: PredicateResult.new(probe_status, %{http_status: 200})
    })
  end

  defp transcript_fixture(events) do
    path =
      Path.join(
        System.tmp_dir!(),
        "starmap-panel-#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(path, Enum.map_join(events, "\n", &Jason.encode!/1))
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "no panel renders until a node is selected", %{conn: conn} do
    seed("quiet-goal")

    {:ok, _view, html} = live(conn, ~p"/starmap")

    refute html =~ ~s(id="starmap-panel")
  end

  test "clicking a canvas node opens the slide-over with identity chips, selection ring, and the analyst link",
       %{conn: conn} do
    run = seed("panel-goal")

    {:ok, view, _html} = live(conn, ~p"/starmap")

    html = view |> element("#canvas-node-group-#{run.run_id}") |> render_click()

    assert html =~ ~s(id="starmap-panel")
    assert html =~ ~s(data-goal-ref="panel-goal")
    # Identity chips: workspace, harness · model, state pill.
    assert html =~ "/tmp/ws"
    assert html =~ "claude · claude-sonnet-5"
    assert html =~ "pill-converging"
    # The selected node carries the selection ring on the canvas.
    assert html =~ ~s(class="selring")
    # Footer link to the full drill-in page.
    assert html =~ "FULL ANALYST VIEW"
    assert html =~ ~s(id="starmap-panel-analyst")
    assert html =~ "/goals/panel-goal/drillin"
  end

  test "the panel shows the DNA strip, convergence heatmap, and budget burn from the goal's history",
       %{conn: conn} do
    run = seed("history-goal", %{max_iterations: 10})
    record("history-goal", 0, vector(:fail, :fail))
    record("history-goal", 1, vector(:pass, :fail))
    record("history-goal", 8, vector(:pass, :pass))

    {:ok, view, _html} = live(conn, ~p"/starmap")

    html = view |> element("#canvas-node-group-#{run.run_id}") |> render_click()

    # ITER line + burn bar at (8+1)/10 = 90% → hot.
    assert html =~ ~s(id="starmap-panel-iter")
    assert html =~ "ITER 8"
    assert html =~ "budget 10 iterations"
    assert html =~ "burn-hot"

    # DNA strip: the latest vector, one square per predicate.
    assert html =~ ~s(id="starmap-panel-dna")
    assert html =~ ~s(data-predicate-id="unit" data-status="pass")
    assert html =~ ~s(data-predicate-id="probe" data-status="pass")

    # Heatmap: one row per predicate, pass AND fail cells across iterations.
    assert html =~ ~s(id="starmap-panel-heatmap")
    assert html =~ ~s(class="hm-row" data-predicate-id="unit")
    assert html =~ ~s(class="hm-row" data-predicate-id="probe")
    assert html =~ ~s(hm-cell status-fail)
    assert html =~ ~s(hm-cell status-pass)
  end

  test "the panel tails the run's transcript: text lines and tool pills, live label for a running run",
       %{conn: conn} do
    path =
      transcript_fixture([
        %{"type" => "text", "text" => "Grace constant is compile-time."},
        %{"type" => "tool_use", "name" => "Bash mix test"}
      ])

    run = seed("tail-goal", %{transcript_sink_path: path})

    {:ok, view, _html} = live(conn, ~p"/starmap")

    html = view |> element("#canvas-node-group-#{run.run_id}") |> render_click()

    assert html =~ ~s(id="starmap-panel-transcript")
    assert html =~ "TRANSCRIPT TAIL · live"
    assert html =~ "Grace constant is compile-time."
    assert html =~ "Bash mix test"
    assert html =~ ~s(class="panel-pill")
  end

  test "a terminal run's tail is labeled post-mortem; no transcript renders the empty state",
       %{conn: conn} do
    run = seed("dead-goal")
    {:ok, _} = RunRegistry.finish(run.run_id, "stuck")

    {:ok, view, _html} = live(conn, ~p"/starmap")

    html = view |> element("#canvas-node-group-#{run.run_id}") |> render_click()

    assert html =~ "TRANSCRIPT TAIL · post-mortem"
    assert html =~ "No transcript events."
    assert html =~ "pill-stuck"
  end

  test "clicking an attention entry opens the panel for that goal", %{conn: conn} do
    seed("attn-goal")

    # Three identical all-fail iterations: the StuckDetector's signal, which
    # ranks an :stuck attention entry for this goal.
    for index <- 0..2 do
      record("attn-goal", index, vector(:fail, :fail))
    end

    {:ok, view, _html} = live(conn, ~p"/starmap")

    html = view |> element(~s(#attention-item-attn-goal-stuck)) |> render_click()

    assert html =~ ~s(id="starmap-panel")
    assert html =~ ~s(data-goal-ref="attn-goal")
  end

  test "the panel shows the session-name chip and the claude resume command", %{conn: conn} do
    run =
      seed("resumable-goal", %{
        session_name: "gtm-sprint",
        harness_session_id: "abc-123-def"
      })

    {:ok, view, _html} = live(conn, ~p"/starmap")

    html = view |> element("#canvas-node-group-#{run.run_id}") |> render_click()

    assert html =~ ~s(class="chip chip-session")
    assert html =~ "gtm-sprint"
    assert html =~ ~s(id="starmap-panel-resume")
    assert html =~ "claude -r abc-123-def"
  end

  test "no resume command without a captured harness session id", %{conn: conn} do
    run = seed("unresumable-goal")

    {:ok, view, _html} = live(conn, ~p"/starmap")

    html = view |> element("#canvas-node-group-#{run.run_id}") |> render_click()

    refute html =~ ~s(id="starmap-panel-resume")
  end

  test "a finished run's honest terminal cause renders as an additive drill-in line (T48.4, ADR-0058)",
       %{conn: conn} do
    run = seed("wedged-goal")

    {:ok, _} =
      RunRegistry.finish(run.run_id, "stuck", %{
        outcome_cause_class: "error_wedged",
        outcome_cause_detail: %{
          "ids" => ["live_route"],
          "reasons" => %{"live_route" => "missing_url"},
          "exhausted" => nil
        }
      })

    {:ok, view, _html} = live(conn, ~p"/starmap")

    html = view |> element("#canvas-node-group-#{run.run_id}") |> render_click()

    assert html =~ ~s(id="starmap-panel-cause")
    assert html =~ "cause: error_wedged"
    assert html =~ "live_route: missing_url"
  end

  test "a budget_exhausted cause renders the exhausted dimension", %{conn: conn} do
    run = seed("exhausted-goal")

    {:ok, _} =
      RunRegistry.finish(run.run_id, "over_budget", %{
        outcome_cause_class: "budget_exhausted",
        outcome_cause_detail: %{
          "ids" => ["code"],
          "reasons" => %{},
          "exhausted" => "max_iterations"
        }
      })

    {:ok, view, _html} = live(conn, ~p"/starmap")

    html = view |> element("#canvas-node-group-#{run.run_id}") |> render_click()

    assert html =~ "cause: budget_exhausted"
    assert html =~ "max_iterations"
  end

  test "no cause classified renders no cause line", %{conn: conn} do
    run = seed("clean-goal")
    {:ok, _} = RunRegistry.finish(run.run_id, "converged")

    {:ok, view, _html} = live(conn, ~p"/starmap")

    html = view |> element("#canvas-node-group-#{run.run_id}") |> render_click()

    refute html =~ ~s(id="starmap-panel-cause")
  end

  test "the close button dismisses the panel", %{conn: conn} do
    run = seed("closeable-goal")

    {:ok, view, _html} = live(conn, ~p"/starmap")

    html = view |> element("#canvas-node-group-#{run.run_id}") |> render_click()
    assert html =~ ~s(id="starmap-panel")

    html = view |> element("#starmap-panel-close") |> render_click()
    refute html =~ ~s(id="starmap-panel")
  end
end

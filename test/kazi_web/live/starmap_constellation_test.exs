defmodule KaziWeb.StarmapConstellationTest do
  @moduledoc """
  Pins the NORMATIVE canvas composition from docs/dashboard-design.md
  ("Canvas composition" section): the starmap's main content is one SVG
  constellation — every registered run is an SVG circle node carrying its
  `nd-*` state class inside wave-band columns, with the event river as a
  bottom bar on the SAME page — and there is NO chip/pill run list.

  This is a READ-ONLY acceptance checker for the goal driving the rework
  (ADR-0042): satisfy it, never edit it. It intentionally asserts markup
  SHAPE (svg > circle.nd-*, band rects, river bar, absence of the chip list)
  rather than pixels; the human browser review against the design mockups
  remains the final gate (devlog 2026-07-06 finding).
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.ReadModel.{Run, RunRegistry}
  alias Kazi.Repo

  defp seed(goal, status_or_nil, opts \\ []) do
    {:ok, run} =
      RunRegistry.start(%{
        run_id: "run-#{System.unique_integer([:positive])}",
        pid: "#PID<0.1.0>",
        workspace: "/tmp/ws",
        goal_ref: goal,
        harness: "claude",
        model: "claude-sonnet-5"
      })

    if status_or_nil, do: RunRegistry.finish(run, status_or_nil)

    if opts[:stale] do
      run
      |> Run.changeset(%{
        "heartbeat_at" => DateTime.add(DateTime.utc_now(), -600, :second)
      })
      |> Repo.update!()
    end

    run
  end

  describe "the fleet renders as an SVG constellation" do
    test "every seeded run is an svg circle node with its nd-* state class; no chip list",
         %{conn: conn} do
      seed("c-landed", "converged")
      seed("c-converging", nil)
      seed("c-stuck", "stuck")
      seed("c-stale", nil, stale: true)

      html = conn |> get("/starmap") |> html_response(200)

      # One <circle class="...nd-<state>..."> per run, inside an <svg>.
      assert html =~ ~r/<svg[^>]*>.*<\/svg>/s

      for {goal, cls} <- [
            {"c-landed", "nd-landed"},
            {"c-converging", "nd-conv"},
            {"c-stuck", "nd-stuck"},
            {"c-stale", "nd-stale"}
          ] do
        assert html =~ ~r/<circle[^>]*#{cls}/,
               "expected an svg circle with #{cls} for #{goal}"

        # The goal name renders as an SVG text label, not a chip.
        assert html =~ ~r/<text[^>]*>[^<]*#{goal}/,
               "expected an svg text label for #{goal}"
      end

      # The pre-constellation chip list must be GONE from the page.
      refute html =~ "starmap-nodes",
             "the chip/pill run list must not render — the circles ARE the fleet view"

      refute html =~ ~r/class="[^"]*starmap-node[ "]/,
             "no .starmap-node chips on the constellation canvas"
    end

    test "wave-band columns render: band fills, separators, and WAVE labels",
         %{conn: conn} do
      seed("b-landed", "converged")
      seed("b-active", nil)

      html = conn |> get("/starmap") |> html_response(200)

      assert html =~ ~r/<rect[^>]*band/, "expected band background rects"
      assert html =~ ~r/wlabel/, "expected .wlabel wave headings"
      assert html =~ ~r/WAVE/, "expected WAVE N band titles"
    end

    test "active nodes carry the pulse ring; the event river bar is on the page",
         %{conn: conn} do
      seed("r-converging", nil)

      html = conn |> get("/starmap") |> html_response(200)

      assert html =~ ~r/<circle[^>]*class="[^"]*ring/,
             "a converging node renders the pulse ring circle"

      assert html =~ "EVENT RIVER", "the river bar renders on the starmap page"
      assert html =~ ~r/ticker/, "the river renders the looping ticker structure"
    end

    test "empty fleet renders the empty state with the canvas shell, no crash",
         %{conn: conn} do
      html = conn |> get("/starmap") |> html_response(200)
      assert html =~ "No runs registered"
    end
  end
end

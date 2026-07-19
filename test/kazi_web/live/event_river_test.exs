defmodule KaziWeb.EventRiverLiveTest do
  @moduledoc """
  LiveView test for the fleet-wide event river (T47.1, UC-061/UC-062,
  ADR-0057).

  Seeds the (sandbox-isolated) run registry with real fixture `events.jsonl`
  files under `tmp_dir` -- no NATS, no harness, no stubbed reader:
  `Kazi.Sink.Events.read/1` reads the same files a real run would append to.
  Asserts: an empty fleet renders the empty state; seeded multi-run sinks
  render newest-first with goal/run tags and working deep links; appending to
  a fixture sink appears on the next tick without restart; a torn final line
  and a missing sink directory render without error.
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.ReadModel.RunRegistry

  @moduletag :tmp_dir

  defp seed(tmp_dir, overrides \\ %{}) do
    path = Path.join(tmp_dir, "events-#{System.unique_integer([:positive])}.jsonl")

    attrs =
      Map.merge(
        %{
          run_id: "run-#{System.unique_integer([:positive])}",
          pid: "#PID<0.1.0>",
          workspace: "/tmp/ws",
          goal_ref: "goal-#{System.unique_integer([:positive])}",
          harness: "claude",
          model: "claude-sonnet-5",
          session_os_pid: "424242",
          events_sink_path: path
        },
        overrides
      )

    {:ok, run} = RunRegistry.start(attrs)
    {run, path}
  end

  defp write(path, lines) do
    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n")
  end

  defp append(path, line) do
    File.write!(path, Jason.encode!(line) <> "\n", [:append])
  end

  defp iteration_event(goal_ref, iteration, observed_at) do
    %{
      "type" => "iteration",
      "goal_ref" => goal_ref,
      "iteration" => iteration,
      "converged" => iteration == 2,
      "observed_at" => observed_at
    }
  end

  test "renders the empty state with no runs registered", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/events")

    assert html =~ ~s(id="event-river-empty")
    refute html =~ ~s(id="event-river-entries")
  end

  test "seeded multi-run sinks render newest-first with goal/run tags and deep links", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {run_a, path_a} = seed(tmp_dir)
    {run_b, path_b} = seed(tmp_dir)

    write(path_a, [iteration_event(run_a.goal_ref, 1, "2026-07-06T10:00:00Z")])
    write(path_b, [iteration_event(run_b.goal_ref, 1, "2026-07-06T10:05:00Z")])

    {:ok, _view, html} = live(conn, ~p"/events")

    assert html =~ ~s(id="event-river-entries")
    assert html =~ ~s(data-event-count="2")

    entry_b = ~s(id="event-river-entry-#{run_b.run_id}-1")
    entry_a = ~s(id="event-river-entry-#{run_a.run_id}-1")
    assert html =~ entry_b
    assert html =~ entry_a
    # newest first: run_b's event (10:05) appears before run_a's (10:00).
    assert String.split(html, entry_b) |> List.first() |> String.length() <
             String.split(html, entry_a) |> List.first() |> String.length()

    assert html =~ ~s(href="/goals/#{run_a.goal_ref}/drillin")
    assert html =~ ~s(href="/runs/#{run_a.run_id}/transcript")
  end

  test "appending to a fixture sink appears on the next tick without restart", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {run, path} = seed(tmp_dir)
    write(path, [iteration_event(run.goal_ref, 1, "2026-07-06T10:00:00Z")])

    {:ok, view, html} = live(conn, ~p"/events")
    assert html =~ ~s(data-event-count="1")

    append(path, iteration_event(run.goal_ref, 2, "2026-07-06T10:01:00Z"))
    send(view.pid, :tick)

    html = render(view)
    assert html =~ ~s(data-event-count="2")
    assert html =~ ~s(id="event-river-entry-#{run.run_id}-2")
  end

  test "a torn final line renders the earlier events without error", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {run, path} = seed(tmp_dir)

    File.write!(
      path,
      Jason.encode!(iteration_event(run.goal_ref, 1, "2026-07-06T10:00:00Z")) <>
        "\n" <> ~s({"type": "iteration", "goal_ref)
    )

    {:ok, _view, html} = live(conn, ~p"/events")

    assert html =~ ~s(data-event-count="1")
    assert html =~ ~s(id="event-river-entry-#{run.run_id}-1")
  end

  test "a run with a missing sink directory renders without error", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {_run, _path} = seed(tmp_dir, %{events_sink_path: Path.join(tmp_dir, "nonexistent.jsonl")})

    {:ok, _view, html} = live(conn, ~p"/events")

    assert html =~ ~s(id="event-river-empty")
  end

  test "a run with no events sink configured contributes zero events", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {:ok, _run} =
      RunRegistry.start(%{
        run_id: "run-#{System.unique_integer([:positive])}",
        pid: "#PID<0.1.0>",
        workspace: "/tmp/ws",
        goal_ref: "goal-#{System.unique_integer([:positive])}",
        events_sink_path: nil
      })

    {:ok, _view, html} = live(conn, ~p"/events")

    assert html =~ ~s(id="event-river-empty")
    refute tmp_dir == nil
  end
end

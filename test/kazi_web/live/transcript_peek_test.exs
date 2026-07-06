defmodule KaziWeb.TranscriptPeekLiveTest do
  @moduledoc """
  LiveView test for the per-run transcript peek (T46.8, UC-062, ADR-0057).

  Seeds the (sandbox-isolated) run registry with a real fixture
  `transcript.jsonl` under `tmp_dir` -- no NATS, no harness, no stubbed reader:
  `Kazi.Sink.Transcript.read/1` reads the same file a real run would tee to.
  Asserts: an unregistered run renders the missing state; a growing fixture
  file streams new lines into the view on the next poll tick while following;
  tool-shaped events render folded to a pill and expand to their payload on
  click; a truncation-marker event renders as an explicit notice; and opening
  a finished run's sink renders its full transcript immediately, with no tick
  required (the same code path as the live-run case).
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.ReadModel.RunRegistry

  @moduletag :tmp_dir

  defp seed(tmp_dir, overrides \\ %{}) do
    path = Path.join(tmp_dir, "transcript-#{System.unique_integer([:positive])}.jsonl")

    attrs =
      Map.merge(
        %{
          run_id: "run-#{System.unique_integer([:positive])}",
          pid: "#PID<0.1.0>",
          workspace: "/tmp/ws",
          goal_ref: "goal-#{System.unique_integer([:positive])}",
          harness: "claude",
          model: "claude-sonnet-5",
          transcript_sink_path: path
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

  test "renders the missing state for an unregistered run", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/runs/never-registered/transcript")

    assert html =~ ~s(id="transcript-peek-missing")
    refute html =~ ~s(id="transcript-events")
  end

  test "a text event renders as a plain line", %{conn: conn, tmp_dir: tmp_dir} do
    {run, path} = seed(tmp_dir)
    write(path, [%{"type" => "text", "text" => "hello from the harness"}])

    {:ok, _view, html} = live(conn, ~p"/runs/#{run.run_id}/transcript")

    assert html =~ ~s(id="transcript-event-0-text")
    assert html =~ "hello from the harness"
  end

  test "a tool event renders folded to a pill and expands to its payload on click", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {run, path} = seed(tmp_dir)

    write(path, [
      %{"type" => "tool_use", "name" => "Edit", "input" => %{"path" => "lib/foo.ex"}}
    ])

    {:ok, view, html} = live(conn, ~p"/runs/#{run.run_id}/transcript")

    assert html =~ ~s(id="toggle-event-0")
    assert html =~ "Edit"
    refute html =~ ~s(id="transcript-event-0-output")

    html = view |> element("#toggle-event-0") |> render_click()

    assert html =~ ~s(id="transcript-event-0-output")
    assert html =~ "lib/foo.ex"

    # Clicking again folds it back.
    html = view |> element("#toggle-event-0") |> render_click()
    refute html =~ ~s(id="transcript-event-0-output")
  end

  test "a truncation-marker event renders as an explicit notice", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {run, path} = seed(tmp_dir)
    write(path, [%{"type" => "truncated", "reason" => "size_cap_exceeded"}])

    {:ok, _view, html} = live(conn, ~p"/runs/#{run.run_id}/transcript")

    assert html =~ ~s(id="transcript-event-0-truncated")
    assert html =~ "Transcript truncated"
    refute html =~ ~s(id="toggle-event-0")
  end

  test "opening a finished run's sink renders the full transcript with no tick required", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {run, path} = seed(tmp_dir)
    write(path, [%{"type" => "text", "text" => "first"}, %{"type" => "text", "text" => "second"}])
    {:ok, _} = RunRegistry.finish(run.run_id, "converged")

    {:ok, _view, html} = live(conn, ~p"/runs/#{run.run_id}/transcript")

    assert html =~ ~s(data-status="converged")
    assert html =~ ~s(data-event-count="2")
    assert html =~ "first"
    assert html =~ "second"
  end

  test "a growing fixture file streams new lines into the view on the next poll tick", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {run, path} = seed(tmp_dir)
    write(path, [%{"type" => "text", "text" => "first"}])

    {:ok, view, html} = live(conn, ~p"/runs/#{run.run_id}/transcript")
    assert html =~ "first"
    refute html =~ "second"

    append(path, %{"type" => "text", "text" => "second"})
    send(view.pid, :tick)

    assert render(view) =~ "second"
  end

  test "toggling follow off freezes the view; toggling it back on resumes tailing", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {run, path} = seed(tmp_dir)
    write(path, [%{"type" => "text", "text" => "first"}])

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.run_id}/transcript")

    html = view |> element("#follow-toggle") |> render_click()
    assert html =~ ~s(data-follow="false")

    append(path, %{"type" => "text", "text" => "second"})
    send(view.pid, :tick)
    refute render(view) =~ "second"

    html = view |> element("#follow-toggle") |> render_click()
    assert html =~ ~s(data-follow="true")

    send(view.pid, :tick)
    assert render(view) =~ "second"
  end
end

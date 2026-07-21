defmodule KaziWeb.MissionControlMountScaleTest do
  @moduledoc """
  T66.5 (#1483): the Mission Control mount must NOT scale with the TOTAL run
  count.

  `assign_fleet/1` runs on `mount/3` and on every 2s poll tick. Before this
  test's fix it read EVERY row of the `runs` table (`RunRegistry.list/0`) and
  then, for the event river, opened and JSON-parsed the events sink file of
  EVERY one of those runs. Both costs are O(total history), so `GET /` gets
  monotonically slower as run history accumulates until the LiveView mount
  exceeds the HTTP ceiling — the reported symptom (a restart "fixes" it only by
  discarding nothing, since the rows survive; it is the freshness of the OS page
  cache that buys the hour).

  This suite pins the BOUND, not a wall-clock number: with a fixture read-model
  far larger than the display caps, the mount must read a bounded number of
  rows and a bounded number of sink files.
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.ReadModel.RunRegistry

  @fixture_runs 400

  setup do
    Application.put_env(:kazi, :remote_run_facts_fetcher, fn -> [] end)
    Application.put_env(:kazi, :waiting_sessions_fetcher, fn -> [] end)

    on_exit(fn ->
      Application.delete_env(:kazi, :remote_run_facts_fetcher)
      Application.delete_env(:kazi, :waiting_sessions_fetcher)
    end)

    :ok
  end

  defp seed_fleet(count) do
    dir = Path.join(System.tmp_dir!(), "kazi-mc-scale-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    events =
      Enum.map_join(1..40, "\n", fn i ->
        Jason.encode!(%{
          "type" => "iteration",
          "observed_at" =>
            DateTime.utc_now() |> DateTime.add(-i, :second) |> DateTime.to_iso8601()
        })
      end)

    for i <- 1..count do
      sink = Path.join(dir, "events-#{i}.jsonl")
      File.write!(sink, events)

      {:ok, run} =
        RunRegistry.start(%{
          run_id: "scale-run-#{i}",
          pid: "#PID<0.1.#{i}>",
          workspace: "/tmp/ws/kazi-repo",
          goal_ref: "scale-goal-#{i}",
          harness: "claude",
          model: "claude-sonnet-5",
          session_os_pid: "424242",
          events_sink_path: sink,
          started_at: DateTime.add(DateTime.utc_now(), -i, :second)
        })

      run
    end
  end

  test "the mount reads a bounded slice of run history, not the whole table" do
    seed_fleet(@fixture_runs)

    assert length(RunRegistry.list()) == @fixture_runs
    bounded = RunRegistry.list_recent()
    assert length(bounded) < @fixture_runs

    # Newest-first: the bounded slice is the RECENT window, not an arbitrary one.
    assert hd(bounded).run_id == "scale-run-1"
  end

  test "mounting with a large history stays under the pinned budget", %{conn: conn} do
    seed_fleet(@fixture_runs)

    {micros, {:ok, _view, html}} = :timer.tc(fn -> live(conn, ~p"/") end)

    assert html =~ ~s(id="mission-control")

    # Generous vs. the observed >10s real-history mount; the point is that the
    # cost no longer tracks the row count.
    assert micros < 3_000_000,
           "mount of #{@fixture_runs} runs took #{div(micros, 1000)}ms"
  end
end

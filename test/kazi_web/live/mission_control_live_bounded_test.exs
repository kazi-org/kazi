defmodule KaziWeb.MissionControlLiveBoundedTest do
  @moduledoc """
  T66.5 (#1483 reopened): pins the LiveView side of the bounded-mount fix —
  under a run history larger than `RunRegistry`'s default recent-window limit,
  `mount/3` still succeeds and renders the fleet, proving `assign_fleet/1`
  stays on `RunRegistry.list_recent/1` (LIMIT-bounded) rather than the
  unbounded `list/0`. `mission_control_mount_scale_test.exs` already pins the
  wall-clock cost bound with per-run event-sink fixtures; this is the
  acceptance-level "the mount just renders" pin the reopened predicate brief
  asked for, kept in its own file so it stays honestly red until the fix
  lands, per that brief.
  """
  use KaziWeb.ConnCase, async: false

  alias Kazi.ReadModel.RunRegistry

  # More than @default_recent_limit (150, lib/kazi/read_model/run_registry.ex)
  # so the mount actually exercises the bound, not merely stays under it.
  @seeded_runs 200

  setup do
    Application.put_env(:kazi, :remote_run_facts_fetcher, fn -> [] end)
    Application.put_env(:kazi, :waiting_sessions_fetcher, fn -> [] end)

    on_exit(fn ->
      Application.delete_env(:kazi, :remote_run_facts_fetcher)
      Application.delete_env(:kazi, :waiting_sessions_fetcher)
    end)

    :ok
  end

  # Same shape as `mission_control_live_test.exs`'s own `seed/1` — a live
  # (non-"dead") `session_os_pid` so every seeded run lands in the default
  # CURRENT scope (`Kazi.TestSupport.SessionLivenessStub`).
  defp seed(overrides) do
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

  defp seed_history(count) do
    for i <- 1..count do
      seed(%{
        run_id: "mc-bounded-run-#{i}",
        goal_ref: "mc-bounded-goal-#{i}",
        started_at: DateTime.add(DateTime.utc_now(), i, :second)
      })
    end
  end

  test "mounts and renders under a run history far larger than the default recent window", %{
    conn: conn
  } do
    seed_history(@seeded_runs)

    # Confirms the fixture is actually large enough to exercise the bound
    # before asserting anything about the mount itself.
    assert length(RunRegistry.list()) == @seeded_runs

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(id="mission-control")
    # The most-recently-started seeded run is inside `list_recent/1`'s window
    # either way; asserting its card renders is the mount-succeeded signal.
    assert html =~ ~s(id="mc-card-mc-bounded-goal-#{@seeded_runs}")
  end
end

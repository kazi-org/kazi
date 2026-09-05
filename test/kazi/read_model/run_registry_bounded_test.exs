defmodule Kazi.ReadModel.RunRegistryBoundedTest do
  @moduledoc """
  Tier 2 — real SQLite boundary (T66.5, #1483 reopened). `run_registry_test.exs`
  pins `list/0`'s (deliberately unbounded) ordering; this is a separate file so
  THIS predicate — the actual reopen gap, a large-history regression test for
  `list_recent/1` — stays honestly red until the bound is proven under a
  fixture larger than the default window, rather than merely existing
  alongside the unbounded-by-design tests.
  """
  use ExUnit.Case, async: false

  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  # More than @default_recent_limit (150, lib/kazi/read_model/run_registry.ex)
  # so the bound is actually exercised, not merely stayed under.
  @seeded_runs 200
  @default_limit 150

  defp run_attrs(overrides) do
    Map.merge(
      %{
        run_id: "run-#{System.unique_integer([:positive])}",
        pid: "#PID<0.123.0>",
        workspace: "/tmp/ws",
        goal_ref: "goal-a",
        harness: "claude",
        model: "claude-sonnet-5"
      },
      overrides
    )
  end

  # Seeds `count` runs with strictly increasing `started_at` (index 1 oldest,
  # `count` newest) via `RunRegistry.start/1`'s own `started_at` override —
  # the same seeding path `mission_control_mount_scale_test.exs` uses to
  # control ordering, rather than reaching around the registry into `Repo`.
  defp seed_history(count) do
    for i <- 1..count do
      {:ok, run} =
        RunRegistry.start(
          run_attrs(%{
            run_id: "hist-run-#{i}",
            started_at: DateTime.add(DateTime.utc_now(), i, :second)
          })
        )

      run
    end
  end

  describe "list_recent/0 under a run history larger than the default window" do
    test "returns at most the default limit, not every seeded row" do
      seed_history(@seeded_runs)

      bounded = RunRegistry.list_recent()

      assert length(bounded) < @seeded_runs
      assert length(bounded) == @default_limit
    end

    test "orders the bounded window most-recently-started first" do
      seed_history(@seeded_runs)

      [newest | _] = RunRegistry.list_recent()

      assert newest.run_id == "hist-run-#{@seeded_runs}"
    end
  end

  describe "list_recent/1 with an explicit smaller limit" do
    test "bounds to the explicit limit rather than the default window" do
      seed_history(@seeded_runs)

      bounded = RunRegistry.list_recent(10)

      assert length(bounded) == 10
      assert hd(bounded).run_id == "hist-run-#{@seeded_runs}"
    end
  end
end

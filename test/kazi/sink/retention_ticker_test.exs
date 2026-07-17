defmodule Kazi.Sink.RetentionTickerTest do
  @moduledoc """
  T60.6 (#1155): the ticker that actually invokes `Kazi.Sink.Events.sweep/2` on a
  schedule. `sweep/2` was correct and unit-tested from the start, but nothing ever
  called it — per-run sink dirs grew without bound. This test pins that (a) the
  tick trigger fires the sweep (proving it is WIRED, not merely existing), (b) an
  aged dir is reclaimed while a young dir is not, and (c) a LIVE run's dir is never
  swept even when aged — using the real `RunRegistry.list_live/0` path.
  """
  use ExUnit.Case, async: false

  alias Kazi.ReadModel.RunRegistry
  alias Kazi.Repo
  alias Kazi.Sink.RetentionTicker

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    sinks_dir =
      Path.join(System.tmp_dir!(), "kazi_sink_retention_#{System.unique_integer([:positive])}")

    File.mkdir_p!(sinks_dir)
    on_exit(fn -> File.rm_rf!(sinks_dir) end)
    {:ok, sinks_dir: sinks_dir}
  end

  # Create <sinks_dir>/<run_id>/events.jsonl and stamp the FILE's mtime old or
  # fresh (sweep/2 keys age on the newest file mtime in the dir).
  defp make_sink(sinks_dir, run_id, age) do
    dir = Path.join(sinks_dir, run_id)
    File.mkdir_p!(dir)
    file = Path.join(dir, "events.jsonl")
    File.write!(file, "{}\n")
    if age == :old, do: File.touch!(file, {{2020, 1, 1}, {0, 0, 0}})
    run_id
  end

  describe "sweep_now/1" do
    test "reclaims aged dirs and leaves young dirs untouched", %{sinks_dir: sinks_dir} do
      make_sink(sinks_dir, "aged-run", :old)
      make_sink(sinks_dir, "young-run", :young)

      assert {:ok, swept} = RetentionTicker.sweep_now(sinks_dir: sinks_dir, live_run_ids: [])

      assert swept == ["aged-run"]
      refute File.dir?(Path.join(sinks_dir, "aged-run"))
      assert File.dir?(Path.join(sinks_dir, "young-run"))
    end

    test "never sweeps a live run's dir even when aged (real RunRegistry.list_live path)",
         %{sinks_dir: sinks_dir} do
      {:ok, live} =
        RunRegistry.start(%{
          run_id: "live-run-#{System.unique_integer([:positive])}",
          pid: "#PID<0.1.0>",
          workspace: "/tmp/ws",
          goal_ref: "goal-a"
        })

      make_sink(sinks_dir, live.run_id, :old)
      make_sink(sinks_dir, "dead-run", :old)

      # No :live_run_ids injected -> the ticker consults RunRegistry.list_live/0.
      assert {:ok, swept} = RetentionTicker.sweep_now(sinks_dir: sinks_dir)

      assert swept == ["dead-run"]
      assert File.dir?(Path.join(sinks_dir, live.run_id))
      refute File.dir?(Path.join(sinks_dir, "dead-run"))
    end

    test "a missing sinks dir is a no-op, not a crash" do
      assert {:ok, []} =
               RetentionTicker.sweep_now(sinks_dir: "/tmp/kazi_no_such_dir_xyz", live_run_ids: [])
    end
  end

  describe "the tick trigger" do
    test "a scheduled tick invokes the sweep", %{sinks_dir: sinks_dir} do
      make_sink(sinks_dir, "aged-run", :old)

      # A separate supervised instance (unique name so it never collides with the
      # application-supervised one) with an injected fixture dir and live set.
      pid =
        start_supervised!(
          {RetentionTicker,
           name: :"retention_ticker_test_#{System.unique_integer([:positive])}",
           sinks_dir: sinks_dir,
           live_run_ids: [],
           check_interval: :timer.hours(1)}
        )

      send(pid, :tick)
      # Force the GenServer to process the tick before asserting its effect.
      :sys.get_state(pid)

      refute File.dir?(Path.join(sinks_dir, "aged-run"))
    end
  end
end

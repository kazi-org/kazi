defmodule Kazi.Daemon.VelocityTickerTest do
  @moduledoc """
  T67.6 (ADR-0079): the production trigger for the opt-in session-stats collector.
  T67.3 shipped `Kazi.Velocity.SessionCollector` but NOTHING invoked
  `SessionCollector.run/1` in production, so the E67 velocity dashboard would
  render over silently-empty session-counter tables (the #1483-class bug). These
  tests pin that the daemon-side ticker drives the collector on an interval,
  honours the opt-in gate, and is crash-isolated.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Kazi.Daemon.VelocityTicker
  alias Kazi.Repo
  alias Kazi.ReadModel.SessionCounters
  alias Kazi.Velocity.SessionCollector

  @fixtures Path.expand("../../support/fixtures/velocity", __DIR__)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    # The ticker writes from its OWN process; shared mode lets it use this
    # connection without a cross-process allow race.
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    System.delete_env("KAZI_VELOCITY_COLLECTOR")
    on_exit(fn -> System.delete_env("KAZI_VELOCITY_COLLECTOR") end)

    state_dir =
      Path.join(System.tmp_dir!(), "kazi-velticker-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(state_dir) end)
    {:ok, state_dir: state_dir}
  end

  defp rows, do: Repo.all(from(s in SessionCounters, order_by: s.session_uuid))

  # A collector run wired to the fixture dir with the bus fact stubbed, so the
  # test asserts only the read-model write path.
  defp real_run(opts) do
    SessionCollector.run(Keyword.merge(opts, machine: "test-host", poster: fn _, _, _ -> :ok end))
  end

  describe "disabled by default" do
    test "the ticker starts but performs NO collection", %{state_dir: state_dir} do
      pid =
        start_supervised!(
          {VelocityTicker,
           name: :velticker_disabled,
           interval_ms: 20,
           dir: @fixtures,
           state_dir: state_dir,
           collect_fun: &real_run/1}
        )

      # Let several intervals elapse; a disabled collector reads no transcript.
      Process.sleep(120)

      assert rows() == []
      status = VelocityTicker.status(pid)
      refute status.enabled
      assert status.last_run_at == nil
      assert status.last_session_count == nil
    end
  end

  describe "enabled via config/env" do
    test "the periodic trigger writes counter rows through the write path", %{
      state_dir: state_dir
    } do
      System.put_env("KAZI_VELOCITY_COLLECTOR", "1")

      pid =
        start_supervised!(
          {VelocityTicker,
           name: :velticker_enabled,
           interval_ms: 20,
           dir: @fixtures,
           state_dir: state_dir,
           collect_fun: &real_run/1}
        )

      # The interval fires collection; the fixture dir has two sessions.
      wait_until(fn -> length(rows()) == 2 end)

      status = VelocityTicker.status(pid)
      assert status.enabled
      assert %DateTime{} = status.last_run_at
      assert status.last_session_count == 2
    end

    test "collect_now drives one synchronous pass", %{state_dir: state_dir} do
      System.put_env("KAZI_VELOCITY_COLLECTOR", "1")

      pid =
        start_supervised!({
          VelocityTicker,
          # Long interval: the only collection is the explicit collect_now.
          name: :velticker_now,
          interval_ms: 3_600_000,
          dir: @fixtures,
          state_dir: state_dir,
          collect_fun: &real_run/1
        })

      assert {:ok, {:ok, collected}} = VelocityTicker.collect_now(pid)
      assert length(collected) == 2
      assert length(rows()) == 2
    end
  end

  describe "interval is configurable" do
    test "interval_s is converted to ms" do
      pid = start_supervised!({VelocityTicker, name: :velticker_intv, interval_s: 42})
      assert :sys.get_state(pid).interval_ms == 42_000
    end

    test "interval_ms overrides interval_s" do
      pid =
        start_supervised!(
          {VelocityTicker, name: :velticker_intv2, interval_s: 42, interval_ms: 7}
        )

      assert :sys.get_state(pid).interval_ms == 7
    end
  end

  describe "crash isolation" do
    test "a collector crash does not take down the ticker", %{state_dir: state_dir} do
      boom = fn _opts -> raise "collector boom" end

      pid =
        start_supervised!(
          {VelocityTicker,
           name: :velticker_boom,
           interval_ms: 3_600_000,
           dir: @fixtures,
           state_dir: state_dir,
           collect_fun: boom}
        )

      # The tick body rescues, so the ticker survives and keeps answering.
      assert {:ok, {:error, :rescued}} = VelocityTicker.collect_now(pid)
      assert Process.alive?(pid)
      assert %{enabled: _} = VelocityTicker.status(pid)
    end
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end

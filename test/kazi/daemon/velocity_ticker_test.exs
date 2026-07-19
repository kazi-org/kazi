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
  alias Kazi.ReadModel.{DeliveryEvent, DeliveryProjection, SessionCounters}
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

  describe "in-daemon writes go direct, never through the control socket (T67.6)" do
    # The T67.6 live wedge: the collector's DEFAULT sink is `Kazi.ReadModel.Writer`,
    # a client seam that routes writes over the daemon control socket when a daemon
    # is alive. Run INSIDE the daemon, that probe finds the daemon alive (itself)
    # and the write blocks on a socket round-trip the daemon must serve while the
    # ticker is busy -- a self-deadlock. The ticker must therefore inject the
    # direct `Repo` sink and never let the collector reach `Writer`.
    test "the tick injects the direct in-daemon write sink, not the socket-routing default",
         %{state_dir: state_dir} do
      test_pid = self()

      capturing = fn opts ->
        send(test_pid, {:collect_opts, opts})
        {:ok, []}
      end

      pid =
        start_supervised!(
          {VelocityTicker,
           name: :velticker_direct_sink,
           interval_ms: 3_600_000,
           dir: @fixtures,
           state_dir: state_dir,
           collect_fun: capturing}
        )

      assert {:ok, {:ok, []}} = VelocityTicker.collect_now(pid)
      assert_received {:collect_opts, opts}
      # The sink handed to the collector is the DIRECT Repo write, never the
      # default `Writer` (socket-routing) path.
      assert Keyword.fetch!(opts, :write) == (&SessionCollector.direct_write/1)
    end

    test "a tick completes and writes even when the control socket would block on connect",
         %{state_dir: state_dir} do
      System.put_env("KAZI_VELOCITY_COLLECTOR", "1")

      # Point the read-model Writer seam at a socket that will NEVER connect: any
      # write that (wrongly) routed through `Writer` would hang here. The direct
      # sink ignores it entirely, so the tick must still complete, bounded.
      prev = Application.get_env(:kazi, :read_model_writer_sock)

      Application.put_env(
        :kazi,
        :read_model_writer_sock,
        Path.join(
          System.tmp_dir!(),
          "kazi-velticker-nonexistent-#{System.unique_integer([:positive])}.sock"
        )
      )

      on_exit(fn ->
        if prev,
          do: Application.put_env(:kazi, :read_model_writer_sock, prev),
          else: Application.delete_env(:kazi, :read_model_writer_sock)
      end)

      pid =
        start_supervised!(
          {VelocityTicker,
           name: :velticker_wedge,
           interval_ms: 3_600_000,
           dir: @fixtures,
           state_dir: state_dir,
           collect_fun: &real_run/1}
        )

      # Bounded: the direct sink never dials the socket, so this returns promptly.
      task = Task.async(fn -> VelocityTicker.collect_now(pid) end)
      assert {:ok, {:ok, {:ok, collected}}} = Task.yield(task, 2_000) || Task.shutdown(task)
      assert length(collected) == 2
      assert length(rows()) == 2
    end
  end

  describe "direct_write persists straight through Repo (T67.6)" do
    test "upserts the counters row on (session_uuid, machine), last-write-wins" do
      base = %{
        "session_uuid" => "11111111-2222-3333-4444-555555555555",
        "machine" => "test-host",
        "message_count" => 3
      }

      assert {:ok, _} = SessionCollector.direct_write(base)
      assert [%SessionCounters{message_count: 3}] = rows()

      # A cumulative re-post collapses to ONE current row (idempotent upsert).
      assert {:ok, _} = SessionCollector.direct_write(%{base | "message_count" => 9})
      assert [%SessionCounters{message_count: 9}] = rows()
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

  defp delivery_rows, do: Repo.all(from(d in DeliveryEvent, order_by: d.dedup_key))

  # A throwaway git workspace whose history has one commit that ticks a plan task
  # and lands a PR -- the minimum the DeliveryProjection derives a row from.
  defp git_fixture_workspace do
    dir =
      Path.join(System.tmp_dir!(), "kazi-velticker-repo-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, "docs"))
    on_exit(fn -> File.rm_rf(dir) end)

    git = fn args -> {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) end
    git.(["init", "-q"])
    git.(["config", "user.email", "t@example.test"])
    git.(["config", "user.name", "t"])
    # Neutralize any developer's global excludesfile (~/.gitignore) so the plan
    # path is never silently ignored on the machine running the suite.
    git.(["config", "core.excludesfile", "/dev/null"])

    File.write!(
      Path.join(dir, "docs/plan.md"),
      "- [x] T1.1 do the thing Done: 2026-07-17 (PR #4242)\n"
    )

    git.(["add", "-A"])
    git.(["commit", "-q", "-m", "docs(plan): tick T1.1 (PR #4242)"])
    dir
  end

  describe "delivery projection (T67.6 finding 2)" do
    test "projects a configured workspace's delivery rows via the DIRECT write path",
         %{state_dir: state_dir} do
      workspace = git_fixture_workspace()

      pid =
        start_supervised!({
          VelocityTicker,
          # No session collection interferes; only the projection writes here.
          name: :velticker_delivery,
          interval_ms: 3_600_000,
          dir: @fixtures,
          state_dir: state_dir,
          collect_fun: fn _opts -> {:ok, []} end,
          workspaces: [workspace]
        })

      assert {:ok, _} = VelocityTicker.collect_now(pid)

      # The commit yields a task_tick and a pr_merge row -- written straight to Repo.
      kinds = delivery_rows() |> Enum.map(& &1.kind) |> Enum.sort()
      assert kinds == ["pr_merge", "task_tick"]

      status = VelocityTicker.status(pid)
      assert %{workspaces_scanned: 1, events_written: 2, at: %DateTime{}} = status.last_projection
    end

    test "injects direct_write/2 as the projection sink, not the socket-routing default",
         %{state_dir: state_dir} do
      test_pid = self()

      capturing = fn workspace, opts ->
        send(test_pid, {:project_opts, workspace, opts})
        {:ok, %{task_ticks: 0, pr_merges: 0, commits: 0}}
      end

      pid =
        start_supervised!(
          {VelocityTicker,
           name: :velticker_delivery_sink,
           interval_ms: 3_600_000,
           dir: @fixtures,
           state_dir: state_dir,
           collect_fun: fn _opts -> {:ok, []} end,
           workspaces: ["/some/workspace"],
           project_fun: capturing}
        )

      assert {:ok, _} = VelocityTicker.collect_now(pid)
      assert_received {:project_opts, "/some/workspace", opts}
      assert Keyword.fetch!(opts, :write) == (&DeliveryProjection.direct_write/2)
    end

    test "projects even when the control socket would block on connect (direct path)",
         %{state_dir: state_dir} do
      workspace = git_fixture_workspace()

      # Point the Writer client seam at a socket that will NEVER connect: any write
      # that (wrongly) routed through `Writer` would hang here. The direct sink
      # ignores it, so the projection must still complete, bounded, and write rows.
      prev = Application.get_env(:kazi, :read_model_writer_sock)

      Application.put_env(
        :kazi,
        :read_model_writer_sock,
        Path.join(
          System.tmp_dir!(),
          "kazi-velticker-delivery-nonexistent-#{System.unique_integer([:positive])}.sock"
        )
      )

      on_exit(fn ->
        if prev,
          do: Application.put_env(:kazi, :read_model_writer_sock, prev),
          else: Application.delete_env(:kazi, :read_model_writer_sock)
      end)

      pid =
        start_supervised!(
          {VelocityTicker,
           name: :velticker_delivery_wedge,
           interval_ms: 3_600_000,
           dir: @fixtures,
           state_dir: state_dir,
           collect_fun: fn _opts -> {:ok, []} end,
           workspaces: [workspace]}
        )

      task = Task.async(fn -> VelocityTicker.collect_now(pid) end)
      assert {:ok, {:ok, _}} = Task.yield(task, 2_000) || Task.shutdown(task)
      assert length(delivery_rows()) == 2
    end

    test "empty workspaces (default): no projection work, last_projection stays nil",
         %{state_dir: state_dir} do
      pid =
        start_supervised!(
          {VelocityTicker,
           name: :velticker_delivery_empty,
           interval_ms: 3_600_000,
           dir: @fixtures,
           state_dir: state_dir,
           collect_fun: fn _opts -> {:ok, []} end}
        )

      assert {:ok, _} = VelocityTicker.collect_now(pid)
      assert delivery_rows() == []
      assert VelocityTicker.status(pid).last_projection == nil
    end

    test "a failing workspace is skipped; the ticker survives and keeps projecting",
         %{state_dir: state_dir} do
      good = git_fixture_workspace()
      missing = Path.join(System.tmp_dir!(), "kazi-velticker-nope-#{System.unique_integer()}")

      pid =
        start_supervised!({
          VelocityTicker,
          # The nonexistent (not-git) path must be skipped, not fatal.
          name: :velticker_delivery_fail,
          interval_ms: 3_600_000,
          dir: @fixtures,
          state_dir: state_dir,
          collect_fun: fn _opts -> {:ok, []} end,
          workspaces: [missing, good]
        })

      assert {:ok, _} = VelocityTicker.collect_now(pid)
      assert Process.alive?(pid)

      # Only the good workspace's rows land; the bad one was skipped.
      assert length(delivery_rows()) == 2
      status = VelocityTicker.status(pid)
      assert status.last_projection.workspaces_scanned == 1
      assert status.last_projection.events_written == 2
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

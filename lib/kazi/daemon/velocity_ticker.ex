defmodule Kazi.Daemon.VelocityTicker do
  @moduledoc """
  T67.6 (ADR-0079): the production trigger for the opt-in session-stats collector
  (`Kazi.Velocity.SessionCollector`).

  T67.3 shipped the collector but nothing invoked `SessionCollector.run/1` in
  production, so the E67 velocity dashboard would render over silently-empty
  session-counter tables (the #1483-class bug). This supervised GenServer, a
  sibling under `Kazi.Daemon.Supervisor`, rides the existing daemon lifecycle
  (ADR-0079: "ride the existing lifecycle, not a second transport") and, on a
  fixed interval, calls `SessionCollector.run/1` so the read-model rows the
  dashboard reads actually get written.

  ## Opt-in preserved (ADR-0034)

  `SessionCollector.run/1` is itself gated on `SessionCollector.enabled?/0` and is
  a no-op (`{:ok, :disabled}`, NO transcript read) when the collector is off. This
  ticker therefore performs NO collection and reads NO transcript on a machine
  that has not opted in -- the only per-tick work is the enabled check. The daemon
  tree still STARTS the ticker unconditionally (so an operator who flips
  `enabled: true` and restarts the daemon gets collection without any other
  change), but a disabled collector costs only the check.

  ## Interval and transcript root

  Both come from `config :kazi, :velocity_collector`:

    * `:interval_s` -- seconds between collection passes (default 300).
    * `:transcript_dir` -- the harness transcript root to scan. Defaults to
      `~/.claude/projects` (the standard Claude Code transcript location).

  Cursors persist under `<state dir>/velocity/cursors` (the same `KAZI_STATE_DIR`
  root the daemon socket uses) so collection stays incremental across daemon
  restarts.

  ## Boot never blocks

  The first collection runs on the first timer tick (`:interval_ms` after boot),
  never synchronously in `init/1`, so a slow first scan cannot delay the daemon
  coming up.

  ## Supervised, crash-isolated

  A tick is wrapped so a collector error is logged and swallowed -- the ticker
  never crash-loops the daemon tree. It is a `one_for_one` child, so even a hard
  crash restarts only the ticker, never the listener/writer.

  ## In-daemon writes go DIRECT, never through the socket (T67.6)

  The collector's default read-model sink is `Kazi.ReadModel.Writer`, a CLIENT
  seam: when a daemon is alive it routes the write over the daemon control socket
  to the single writer (ADR-0068). But this ticker runs INSIDE the daemon, so
  that probe would find the daemon alive (itself) and the ticker would block
  waiting on a control-socket round-trip the daemon must serve -- while `kazi
  daemon status` also calls into this ticker -- self-deadlocking the daemon (the
  T67.6 live wedge: with the collector enabled, v1.262.0 wedged exactly one
  interval after boot). The daemon IS the single writer, so the ticker injects
  `Kazi.Velocity.SessionCollector.direct_write/1` as the collector's `:write`
  sink: a direct `Kazi.Repo` upsert, the same mechanism `Kazi.Daemon.Write` uses
  to apply a client batch. The ticker's writes therefore never touch its own
  socket.

  The collector's OTHER ship -- the bus `fact` (`Kazi.Bus.post/3`) -- does dial
  the control socket to discover the NATS port, but is safe in-daemon: every
  `Kazi.Bus` call runs under `Kazi.Bus.run/3`'s hard deadline (it degrades to
  `{:error, :bus_unavailable}` rather than block past the bound), and the
  collector additionally swallows any post error. It can never wedge the daemon
  the way the unbounded `Writer` socket write did.

  ## Observability

  `status/1` reports `{enabled?, last run's timestamp, last run's session count}`
  from real runs only (never fabricated) so `kazi daemon status` can show the
  operator the collector is alive.
  """

  use GenServer
  require Logger

  alias Kazi.Velocity.SessionCollector

  @default_interval_s 300

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The default seconds between collection passes."
  @spec default_interval_s() :: pos_integer()
  def default_interval_s, do: @default_interval_s

  @impl true
  def init(opts) do
    interval_ms =
      Keyword.get(opts, :interval_ms) ||
        (Keyword.get(opts, :interval_s) || configured_interval_s()) * 1000

    state = %{
      interval_ms: interval_ms,
      dir: Keyword.get(opts, :dir, default_dir()),
      state_dir: Keyword.get(opts, :state_dir, default_state_dir()),
      # Injectable so a test drives a deterministic collector (default: the real
      # opt-in-gated collector). `(keyword -> {:ok, term})`.
      collect_fun: Keyword.get(opts, :collect_fun, &SessionCollector.run/1),
      # The read-model sink the collector writes through. We run INSIDE the
      # daemon, which is the ADR-0068 single writer, so we MUST write direct to
      # `Kazi.Repo` -- never through `Kazi.ReadModel.Writer`, whose client seam
      # would probe the daemon control socket, find it alive (itself), and route
      # the write back over that socket, self-deadlocking the daemon (T67.6 live
      # wedge). Injectable so a test can pin the sink. `(map -> term())`.
      write_fun: Keyword.get(opts, :write_fun, &SessionCollector.direct_write/1),
      last_run_at: nil,
      last_session_count: nil
    }

    schedule(state.interval_ms)
    {:ok, state}
  end

  @doc """
  Enabled state plus the last real run's timestamp and session count. Fields are
  `nil` until the first run that actually collected (a disabled machine leaves
  them `nil`). Best-effort: a ticker that is not running or not answering yields
  `%{enabled: <check>, last_run_at: nil, last_session_count: nil}`.
  """
  @spec status(GenServer.server()) :: %{
          enabled: boolean(),
          last_run_at: DateTime.t() | nil,
          last_session_count: non_neg_integer() | nil
        }
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    _, _ ->
      %{enabled: safe_enabled?(), last_run_at: nil, last_session_count: nil}
  end

  @doc """
  Run one collection pass synchronously and return the collector result -- the
  timer body, public so tests drive it without waiting on the interval. Honours
  the opt-in gate exactly as the timer path does.
  """
  @spec collect_now(GenServer.server()) :: {:ok, term()}
  def collect_now(server \\ __MODULE__) do
    GenServer.call(server, :collect_now)
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      enabled: safe_enabled?(),
      last_run_at: state.last_run_at,
      last_session_count: state.last_session_count
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:collect_now, _from, state) do
    {result, state} = run_tick(state)
    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_info(:collect, state) do
    {_result, state} = run_tick(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # One collection pass. `run/1` is a no-op returning `{:ok, :disabled}` when the
  # collector is off, so a disabled machine reads NO transcript here. On a run
  # that collected, record the timestamp + session count for observability. All
  # errors are logged and swallowed -- a tick never crashes the ticker.
  defp run_tick(state) do
    result =
      state.collect_fun.(dir: state.dir, state_dir: state.state_dir, write: state.write_fun)

    case result do
      {:ok, collected} when is_list(collected) ->
        {result,
         %{state | last_run_at: DateTime.utc_now(), last_session_count: length(collected)}}

      _disabled_or_other ->
        {result, state}
    end
  rescue
    error ->
      Logger.debug("kazi daemon: velocity collection failed (#{Exception.message(error)})")
      {{:error, :rescued}, state}
  catch
    kind, reason ->
      Logger.debug(
        "kazi daemon: velocity collection failed (#{inspect(kind)}: #{inspect(reason)})"
      )

      {{:error, :caught}, state}
  end

  defp safe_enabled? do
    SessionCollector.enabled?()
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp configured_interval_s do
    Application.get_env(:kazi, :velocity_collector, [])[:interval_s] || @default_interval_s
  end

  defp default_dir do
    Application.get_env(:kazi, :velocity_collector, [])[:transcript_dir] ||
      Path.expand(Path.join(["~", ".claude", "projects"]))
  end

  defp default_state_dir do
    root =
      System.get_env("KAZI_STATE_DIR") || Path.join([System.user_home() || File.cwd!(), ".kazi"])

    Path.join([root, "velocity", "cursors"])
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :collect, interval_ms)
end

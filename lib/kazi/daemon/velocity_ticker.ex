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

  ## The tick never blocks the ticker mainloop (#1595)

  The collection+projection pass runs in an ISOLATED monitored child process, not
  inline in this GenServer. A pass that hangs forever (the #1595 live wedge: a
  session-transcript scan that never returned on the first 300s tick) therefore
  can NEVER wedge the ticker — `:status` reads stay instant, so the daemon's
  status control op (`Kazi.Daemon.Control` → `VelocityTicker.status/1`, a
  `GenServer.call` into this process) can never go alive-but-deaf behind a stuck
  pass. The child is bounded by a hard `collect_timeout_ms` deadline: an overrun
  is killed and logged at `:error` (a hung collector must never persist — the
  crash-only guard the issue asks for). An overlapping tick (a previous pass still
  running when the next interval fires) is skipped, never queued, so passes cannot
  pile up. The synchronous `collect_now/1` remains an explicit opt-in blocking call
  for tests/debug.

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

  ## Delivery projection (T67.6 finding 2)

  T67.2 shipped `Kazi.ReadModel.DeliveryProjection.project/2` but nothing invoked
  it in production, so the E67 dashboard's DELIVERY half rendered over an empty
  `delivery_events` table (the same no-callers class as the collector). After
  session collection each tick, this ticker projects every workspace listed under
  `config :kazi, :velocity_collector, workspaces: [paths]` (default `[]` -- no
  projection). The scan is incremental (`since: last_seen_commit()`) and the upsert
  is idempotent, so a re-scan of unchanged history writes nothing new. The
  projection is independent of and crash-isolated from session collection: a
  failing workspace (nonexistent / not-git / format-broken) is logged and skipped,
  never killing the ticker or the other workspaces. It writes DIRECT
  (`DeliveryProjection.direct_write/2`) for exactly the in-daemon self-deadlock
  reason above -- never through `Kazi.ReadModel.Writer`'s socket-routing seam.

  ## Observability

  `status/1` reports `{enabled?, last run's timestamp, last run's session count}`
  from real runs only (never fabricated), plus the last delivery-projection pass
  (`{workspaces_scanned, events_written, at}` or `nil` before the first pass), so
  `kazi daemon status` can show the operator both halves are alive.

  It ALSO reports `passes_killed` (+ `last_kill_at`): a run-lifetime count of
  passes killed at the `collect_timeout_ms` deadline (#1606). This makes a pass
  that dies every tick OBSERVABLE from `kazi daemon status` alone — the live #1606
  gap was that the `:error` kill log did not reach the LaunchAgent's log file, so
  a silently-killed pass looked identical to "no run yet". A status counter that
  does not depend on log delivery closes that gap; the bounded transcript scan
  (`SessionCollector`, `:max_bytes`) then keeps a real pass from being killed at
  all so the counter stays at 0 in steady state.
  """

  use GenServer
  require Logger

  alias Kazi.ReadModel.DeliveryProjection
  alias Kazi.Velocity.SessionCollector

  @default_interval_s 300
  @default_collect_timeout_ms 120_000

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
      # T67.6 finding 2: the delivery half of the E67 dashboard. Each configured
      # workspace's git history is projected into `delivery_events` after session
      # collection every tick. Same in-daemon invariant: the projection MUST write
      # direct (`DeliveryProjection.direct_write/2`), never through `Writer`.
      workspaces: Keyword.get(opts, :workspaces, configured_workspaces()),
      project_fun: Keyword.get(opts, :project_fun, &DeliveryProjection.project/2),
      delivery_write_fun:
        Keyword.get(opts, :delivery_write_fun, &DeliveryProjection.direct_write/2),
      # The incremental cursor: the newest already-projected landing commit. A
      # seam so a test drives a deterministic `<since>..HEAD` range.
      last_seen_fun: Keyword.get(opts, :last_seen_fun, &DeliveryProjection.last_seen_commit/0),
      last_run_at: nil,
      last_session_count: nil,
      last_projection: nil,
      # #1595: the collection+projection pass runs in an ISOLATED monitored child,
      # never inline in this GenServer, so a pass that hangs forever can never
      # wedge the ticker's mainloop (and thus never block the daemon status path,
      # which `GenServer.call`s into `:status`). `pass` is `nil` when idle, or
      # `%{pid, ref}` while a pass runs; a hung pass is killed after
      # `collect_timeout_ms` and logged LOUD. A second tick that fires while a
      # pass is still running is skipped (never piled up).
      pass: nil,
      collect_timeout_ms: Keyword.get(opts, :collect_timeout_ms, configured_collect_timeout_ms()),
      # #1606: a run-lifetime counter of passes KILLED at the collect_timeout
      # deadline, surfaced in `kazi daemon status` so a pass that dies every tick
      # is OBSERVABLE without depending on the :error log reaching the LaunchAgent
      # log file (the live #1606 gap: no kill log appeared even though the deadline
      # elapsed). `last_kill_at` timestamps the most recent kill.
      passes_killed: 0,
      last_kill_at: nil
    }

    schedule(state.interval_ms)
    {:ok, state}
  end

  @doc """
  Enabled state plus the last real run's timestamp and session count, and the last
  delivery-projection pass (`%{workspaces_scanned, events_written, at}` or `nil`).
  Fields are `nil` until the first run that actually collected/projected (a disabled
  machine leaves the collection fields `nil`; an empty `workspaces` list leaves
  `last_projection` `nil`). Best-effort: a ticker that is not running or not
  answering yields all-`nil` run fields.
  """
  @spec status(GenServer.server()) :: %{
          enabled: boolean(),
          last_run_at: DateTime.t() | nil,
          last_session_count: non_neg_integer() | nil,
          passes_killed: non_neg_integer(),
          last_kill_at: DateTime.t() | nil,
          last_projection:
            %{
              workspaces_scanned: non_neg_integer(),
              events_written: non_neg_integer(),
              at: DateTime.t()
            }
            | nil
        }
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    _, _ ->
      %{
        enabled: safe_enabled?(),
        last_run_at: nil,
        last_session_count: nil,
        passes_killed: 0,
        last_kill_at: nil,
        last_projection: nil
      }
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
      workspaces: state.workspaces,
      last_run_at: state.last_run_at,
      last_session_count: state.last_session_count,
      passes_killed: state.passes_killed,
      last_kill_at: state.last_kill_at,
      last_projection: state.last_projection
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:collect_now, _from, state) do
    # The explicit synchronous test/debug path: run the pass inline and return the
    # collector result. NOT the production wedge vector — the periodic timer path
    # below never runs inline. A caller that invokes this opts into blocking.
    {result, state} = run_tick(state)
    state = run_projection(state)
    {:reply, {:ok, result}, state}
  end

  # #1595: the PERIODIC tick. The pass runs in a monitored child, so this returns
  # immediately and the ticker stays responsive to `:status` no matter how long
  # (or forever) the collector blocks. Always reschedule the next interval; an
  # overlapping tick (previous pass still running) is skipped, never queued.
  @impl true
  def handle_info(:collect, %{pass: nil} = state) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {:pass_done, self(), run_pass(state)}) end)
    Process.send_after(self(), {:pass_timeout, ref}, state.collect_timeout_ms)
    schedule(state.interval_ms)
    {:noreply, %{state | pass: %{pid: pid, ref: ref}}}
  end

  def handle_info(:collect, state) do
    Logger.warning(
      "kazi daemon: velocity pass still running after #{state.interval_ms}ms; skipping this tick"
    )

    schedule(state.interval_ms)
    {:noreply, state}
  end

  # A pass finished cleanly: adopt only the observability deltas it computed (the
  # only fields a pass mutates), demonitor, and go idle.
  def handle_info({:pass_done, pid, deltas}, %{pass: %{pid: pid, ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, apply_pass_deltas(state, deltas)}
  end

  # The pass process went down WITHOUT delivering a result. `run_pass/1` is fully
  # guarded (a collector error is caught, not raised), so this is the killed-on-
  # timeout DOWN or an unexpected crash — either way go idle, never wedged.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{pass: %{ref: ref}} = state) do
    {:noreply, %{state | pass: nil}}
  end

  # A pass overran its hard deadline: kill it LOUD (a hung collector must never
  # persist), release the monitor, go idle. This is the crash-only guard for the
  # collector half (#1595) — deaf-but-running is impossible because the pass is
  # off the mainloop AND bounded.
  def handle_info({:pass_timeout, ref}, %{pass: %{ref: ref, pid: pid}} = state) do
    killed = state.passes_killed + 1

    Logger.error(
      "kazi daemon: velocity pass exceeded #{state.collect_timeout_ms}ms and was killed " <>
        "(a hung session-transcript scan or projection); the daemon stayed responsive " <>
        "(#{killed} pass(es) killed at the deadline so far)"
    )

    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | pass: nil, passes_killed: killed, last_kill_at: DateTime.utc_now()}}
  end

  # A stale timeout/down for a pass that already completed — ignore.
  def handle_info({:pass_timeout, _ref}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  # Run one full pass (session collection + delivery projection) OFF the ticker
  # mainloop, returning only the observability deltas the ticker adopts. Runs in
  # the monitored child; `run_tick`/`run_projection` already catch every collector
  # error, so this never raises.
  defp run_pass(state) do
    {_result, state} = run_tick(state)
    state = run_projection(state)

    %{
      last_run_at: state.last_run_at,
      last_session_count: state.last_session_count,
      last_projection: state.last_projection
    }
  end

  defp apply_pass_deltas(state, deltas) do
    %{
      state
      | pass: nil,
        last_run_at: deltas.last_run_at,
        last_session_count: deltas.last_session_count,
        last_projection: deltas.last_projection
    }
  end

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

  # T67.6 finding 2: project each configured workspace's delivery events after
  # session collection. Independent of collection and per-workspace crash-isolated
  # -- a failing (nonexistent / not-git / format-broken) workspace is logged and
  # skipped, never killing the ticker or the other workspaces. An empty workspace
  # list is a no-op that leaves `last_projection` untouched (no fabricated pass).
  defp run_projection(%{workspaces: []} = state), do: state

  defp run_projection(state) do
    since = safe_last_seen(state)

    {scanned, written} =
      Enum.reduce(state.workspaces, {0, 0}, fn workspace, {scanned, written} ->
        case project_workspace(state, workspace, since) do
          {:ok, count} -> {scanned + 1, written + count}
          :error -> {scanned, written}
        end
      end)

    projection = %{workspaces_scanned: scanned, events_written: written, at: DateTime.utc_now()}
    %{state | last_projection: projection}
  end

  # One workspace's projection, fully isolated. Returns `{:ok, events_written}` on a
  # clean pass or `:error` (logged) on any failure, so one bad workspace never
  # aborts the reduce.
  defp project_workspace(state, workspace, since) do
    case state.project_fun.(workspace, since: since, write: state.delivery_write_fun) do
      {:ok, summary} ->
        {:ok, summary.task_ticks + summary.pr_merges}

      {:error, reason} ->
        Logger.debug("kazi daemon: delivery projection skipped #{workspace} (#{inspect(reason)})")

        :error
    end
  rescue
    error ->
      Logger.debug(
        "kazi daemon: delivery projection failed for #{workspace} (#{Exception.message(error)})"
      )

      :error
  catch
    kind, reason ->
      Logger.debug(
        "kazi daemon: delivery projection failed for #{workspace} (#{inspect(kind)}: #{inspect(reason)})"
      )

      :error
  end

  # The incremental cursor, guarded: a read-model read that raises must not abort
  # the tick -- fall back to a full scan (`nil` since), which is idempotent anyway.
  defp safe_last_seen(state) do
    state.last_seen_fun.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
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

  # #1595: the hard deadline a single collection+projection pass may run before it
  # is killed. A real pass completes in seconds; this bound only ever fires on a
  # pathological hang (the wedge this fix prevents). Default 120s, overridable via
  # `config :kazi, :velocity_collector, collect_timeout_s: N` or the `:collect_timeout_ms`
  # opt (the test seam).
  defp configured_collect_timeout_ms do
    case Application.get_env(:kazi, :velocity_collector, [])[:collect_timeout_s] do
      s when is_integer(s) and s > 0 -> s * 1000
      _ -> @default_collect_timeout_ms
    end
  end

  # The workspaces whose delivery events the ticker projects each tick (default
  # `[]` -- no projection). Non-list config degrades to `[]` rather than crashing
  # the ticker's `init/1`.
  #
  # `KAZI_VELOCITY_WORKSPACES` (colon-separated absolute paths) is read directly
  # here at init time, taking precedence over app-env. On the Burrito release
  # binary the daemon supervision tree (this ticker's `init/1`) boots BEFORE the
  # `config/runtime.exs` provider has applied its override to app-env, so a
  # provider-set `:workspaces` value is not yet visible when the ticker starts
  # (T67.6 gap 4). Reading the env at call time -- mirroring how
  # `SessionCollector.enabled?/0` reads `KAZI_VELOCITY_COLLECTOR` -- is immune to
  # that boot ordering. Unset falls back to the compile-time app-env config.
  defp configured_workspaces do
    case System.get_env("KAZI_VELOCITY_WORKSPACES") do
      value when is_binary(value) -> String.split(value, ":", trim: true)
      _ -> app_env_workspaces()
    end
  end

  defp app_env_workspaces do
    case Application.get_env(:kazi, :velocity_collector, [])[:workspaces] do
      paths when is_list(paths) -> paths
      _ -> []
    end
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

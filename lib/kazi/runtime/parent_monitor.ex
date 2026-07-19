defmodule Kazi.Runtime.ParentMonitor do
  @moduledoc """
  Reaps a launcher-killed dispatch tree (issue #1073, a regression of #857).

  The released binary is a burrito NATIVE LAUNCHER that execs the BEAM. When a
  terminal closes, the OS delivers SIGTERM to that LAUNCHER, not to the BEAM.
  Both #857 mechanisms watch the BEAM, so neither covers this case:

    * `Kazi.Harness.ChildSupervisor`'s wrapper watchdog polls
      `parent_pid = System.pid()` -- the BEAM's OWN pid. When the launcher dies
      the BEAM merely re-parents to init (ppid=1) and keeps running, so the
      watchdog's `kill -0 parent` never fails and the harness child is never
      reaped.
    * `Kazi.Runtime.Finalizer`'s SIGTERM trap never fires, because the launcher
      does not forward the signal to the BEAM.

  Net effect: `claude -p` runs to natural completion, orphaned, burning real
  cost. This monitor closes that gap from INSIDE the BEAM: it records the
  launcher's pid once (the BEAM's parent at startup), polls its liveness, and
  once the launcher is gone for `dead_threshold` CONSECUTIVE reads it records the
  run's termination and `System.halt/1`s. Halting closes the dispatch port, which
  lets the EXISTING per-dispatch watchdog reap `claude` from the correct trigger
  -- this module does not reimplement the reaping, it triggers it from the one
  signal the launcher's death actually produces.

  This is Layer A. Layer B (the launcher forwarding SIGTERM/SIGINT to the BEAM)
  is defense-in-depth tracked as a separate burrito-fork issue (ADR-0066) and is
  NOT implemented here.

  ## Why `dead_threshold` consecutive reads, not one

  A single `ps`/`kill -0` misread (a transient fork failure under load) must
  never halt a HEALTHY run. Requiring N consecutive DEAD reads before halting
  turns a one-off misread into a reset rather than an abort (R-E54-3). A live
  read at any point resets the counter.

  ## Test seams

  `:parent_pid`, `:poll_ms`, `:dead_threshold`, `:alive_fn`, and `:on_dead` are
  all injectable so a test can point the monitor at a SYNTHETIC launcher pid and
  a stub death-handler -- proving the fire/no-fire behaviour without halting the
  test BEAM. Only the real CLI entrypoint (`Kazi.Runtime` under the burrito
  standalone binary) wires the production `on_dead` that actually halts.
  """

  use GenServer

  require Logger

  alias Kazi.Harness.ChildSupervisor
  alias Kazi.Runtime.Finalizer

  @default_poll_ms 1_000
  @default_dead_threshold 3

  @doc """
  Starts a parent-liveness monitor.

  Options:

    * `:parent_pid` -- the launcher pid to watch. Defaults to the BEAM's parent
      (`ps -o ppid=`), resolved ONCE at init. A monitor that cannot resolve a
      launcher pid stays inert (it never polls and never fires) rather than guess.
    * `:run_id` -- the run whose termination `on_dead` records (production only).
    * `:poll_ms` -- liveness poll interval (default #{@default_poll_ms}).
    * `:dead_threshold` -- consecutive DEAD reads required before firing
      (default #{@default_dead_threshold}, floored at 1).
    * `:alive_fn` -- 1-arity liveness predicate (default `ChildSupervisor.alive?/1`).
    * `:on_dead` -- 1-arity handler run once the threshold is reached, given the
      state map (default records termination then `System.halt(0)`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    # An EXPLICIT `:parent_pid` (even nil) is respected; only its ABSENCE falls
    # back to resolving the BEAM's real parent. This lets a caller/test force the
    # inert path with `parent_pid: nil`, and keeps production (no key) resolving.
    parent_pid =
      if Keyword.has_key?(opts, :parent_pid) do
        Keyword.get(opts, :parent_pid)
      else
        resolve_launcher_pid()
      end

    state = %{
      parent_pid: parent_pid,
      run_id: Keyword.get(opts, :run_id),
      poll_ms: Keyword.get(opts, :poll_ms, @default_poll_ms),
      dead_threshold: max(Keyword.get(opts, :dead_threshold, @default_dead_threshold), 1),
      alive_fn: Keyword.get(opts, :alive_fn, &ChildSupervisor.alive?/1),
      on_dead: Keyword.get(opts, :on_dead, &default_on_dead/1),
      dead_count: 0
    }

    # No launcher pid resolved (ppid=1, a `ps` failure, a blank read) -> stay
    # inert: an idle process that never polls, so it can never halt a run on no
    # evidence. This is the safe default the whole design leans on.
    if is_nil(state.parent_pid) do
      {:ok, state}
    else
      schedule_poll(state.poll_ms)
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    if state.alive_fn.(state.parent_pid) do
      # A live read resets the counter: only CONSECUTIVE dead reads fire.
      schedule_poll(state.poll_ms)
      {:noreply, %{state | dead_count: 0}}
    else
      dead_count = state.dead_count + 1

      if dead_count >= state.dead_threshold do
        state.on_dead.(state)
        {:noreply, %{state | dead_count: dead_count}}
      else
        schedule_poll(state.poll_ms)
        {:noreply, %{state | dead_count: dead_count}}
      end
    end
  end

  defp schedule_poll(poll_ms), do: Process.send_after(self(), :poll, poll_ms)

  # The BEAM's parent at startup IS the launcher (issue #1073). `ps -o ppid=`
  # prints just the ppid (the trailing `=` suppresses the header). Any failure
  # -- no `ps`, a blank read -- resolves to nil, and a nil pid keeps the monitor
  # inert rather than watching the wrong process.
  defp resolve_launcher_pid do
    case System.cmd("ps", ["-o", "ppid=", "-p", System.pid()], stderr_to_stdout: true) do
      {out, 0} ->
        case String.trim(out) do
          "" -> nil
          ppid -> ppid
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # Production death handler: record the run's termination (best-effort, like
  # every other registry touch) THEN halt. Halting closes the dispatch port so
  # the per-dispatch watchdog reaps `claude` from the launcher's death.
  defp default_on_dead(state) do
    Logger.warning(fn ->
      "kazi: launcher process #{state.parent_pid} is gone; halting to reap this run's " <>
        "dispatch tree (issue #1073)"
    end)

    if is_binary(state.run_id) do
      Finalizer.record_termination(state.run_id, {:launcher_gone, state.parent_pid})
    end

    System.halt(0)
  end
end

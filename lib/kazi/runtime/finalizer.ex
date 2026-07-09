defmodule Kazi.Runtime.Finalizer do
  @moduledoc """
  Runs run-finalization when a `Kazi.Runtime` run terminates — including when the
  controller receives an EXTERNAL OS termination signal (SIGTERM from a container
  stop or `kill`, SIGINT from Ctrl-C), not only on the normal terminal path
  (issue #856/#857, T0.13).

  Finalization is best-effort on every path — a finalization failure must never
  alter the run's outcome. Two layers cooperate:

    * `install_signal_trap/2` registers OS-signal handlers (via
      `System.trap_signal/3`, which drives `:os.set_signal/2` under the hood) so
      that when the BEAM is asked to stop from outside, the active run's
      termination is recorded in the run registry BEFORE the VM halts. Without
      this an externally-killed run leaves a stale `running` row forever,
      invisible to recovery and observability.
    * `finalize/4` is the normal terminal hook `Kazi.Runtime.run/2` calls once the
      loop reaches a terminal state: it drains any trapped linked-process exits,
      records them, and removes the signal handlers so a later operation in the
      same VM does not inherit a trap pointing at a finished run.

  The `ChildSupervisor.wrap/3` wrapper script (outside the BEAM) handles OS-level
  reaping of the harness subprocess itself; this module coordinates the
  application-level record-keeping that must survive an abnormal exit.
  """

  require Logger

  alias Kazi.ReadModel.RunRegistry

  # The OS signals that mean "something outside the BEAM wants this run to stop":
  # SIGTERM (container stop, `kill`, systemd) and SIGINT (Ctrl-C).
  @external_signals [:sigterm, :sigint]

  @doc """
  Installs OS-termination-signal handlers for the calling run and traps linked
  child exits.

  On SIGTERM/SIGINT the handler records the run's termination in the registry
  (best-effort) and then halts the VM, so an externally-killed run still leaves
  an accurate terminal row rather than a stale `running` one. Trapping linked
  exits (`:trap_exit`) additionally converts a crashing harness child into a
  `{:EXIT, _, _}` message the terminal `finalize/4` drain records.

  Returns the `[{signal, id}]` handles the installed traps were registered under,
  so `finalize/4` can remove them. Returns `[]` when persistence is off (there is
  no registry row to record against) or when the runtime refuses a trap.
  """
  @spec install_signal_trap(String.t(), boolean()) :: [{atom(), reference()}]
  def install_signal_trap(_run_id, false), do: []

  def install_signal_trap(run_id, true) when is_binary(run_id) do
    Process.flag(:trap_exit, true)

    @external_signals
    |> Enum.map(&install_one(&1, run_id))
    |> Enum.reject(&is_nil/1)
  end

  # Register a single OS signal handler; nil (logged, never raised) if the
  # runtime declines to trap it, so one refused signal never blocks the others.
  defp install_one(signal, run_id) do
    case System.trap_signal(signal, fn -> on_external_signal(run_id, signal) end) do
      {:ok, id} ->
        {signal, id}

      other ->
        Logger.debug(fn ->
          "kazi.runtime.finalizer could not trap #{signal}: #{inspect(other)}"
        end)

        nil
    end
  rescue
    error ->
      Logger.debug(fn ->
        "kazi.runtime.finalizer could not trap #{signal}: #{Exception.message(error)}"
      end)

      nil
  end

  # Runs inside the `:erl_signal_server` when the OS signal arrives: record the
  # run's termination, then halt so the external stop still takes effect. We own
  # the halt now that we've intercepted the default signal disposition.
  defp on_external_signal(run_id, signal) do
    record_termination(run_id, {:signal, signal})
    System.halt(0)
  end

  @doc """
  Finalizes a completed run: drains any trapped linked-process exits into the
  registry and removes the OS-signal handlers `install_signal_trap/2` set up.

  Called after the loop terminates but before the result is returned. Returns
  `:ok` regardless of any finalization error — cleanup must never alter the run
  outcome. A no-op when persistence is off.
  """
  @spec finalize(Kazi.Loop.result(), String.t(), boolean(), [{atom(), reference()}]) :: :ok
  def finalize(result, run_id, persist?, signal_trap \\ [])

  def finalize(_result, _run_id, false, _signal_trap), do: :ok

  def finalize(_result, run_id, true, signal_trap) do
    handle_trapped_exits(run_id)
    remove_signal_trap(signal_trap)
    :ok
  end

  defp handle_trapped_exits(run_id) do
    receive do
      # A `:normal` exit from a linked process (e.g. a completed helper task)
      # is not a termination event — recording it would also re-enter a
      # registry write whose own helper task could feed this drain forever.
      {:EXIT, _pid, :normal} ->
        handle_trapped_exits(run_id)

      {:EXIT, _pid, reason} ->
        record_termination(run_id, reason)
        handle_trapped_exits(run_id)
    after
      0 -> :ok
    end
  end

  defp remove_signal_trap(signal_trap) do
    Enum.each(signal_trap, fn {signal, id} ->
      _ = System.untrap_signal(signal, id)
    end)
  rescue
    _ -> :ok
  end

  @doc """
  Records an external termination event in the run registry when a harness
  subprocess or the controller terminates abnormally. Called when a trapped OS
  signal fires or a trapped linked-process exit is received.

  Best-effort: registry writes are observational and must never alter run
  outcomes.
  """
  @spec record_termination(binary(), term()) :: :ok
  def record_termination(run_id, reason) do
    case RunRegistry.record_termination(run_id, reason) do
      {:ok, _} ->
        :ok

      {:error, err} ->
        Logger.warning(fn ->
          "kazi.runtime.finalizer failed to record termination for run #{run_id}: " <>
            inspect(err)
        end)

        :ok
    end
  end
end

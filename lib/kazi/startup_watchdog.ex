defmodule Kazi.StartupWatchdog do
  @moduledoc """
  A diagnostic watchdog for the CLI-startup path (T59.3, issue #1255).

  #1255 reported the first `kazi` invocation after an upgrade hanging FOREVER —
  idle schedulers, no busy loop, no DB/network fd — the signature of a `receive`
  with no `after` clause blocking one process indefinitely (the confirmed
  `Gnat.Jetstream.Pager` case was fixed in #1266, but the original `kazi version`
  specimen stayed unreproducible; see the T59.3 devlog entry). A black-box hang
  like that took a native stack sample + `lsof` and, in the live specimens, hours
  to even notice.

  This wraps the CLI dispatch each entry point runs (`Kazi.CLI.main/1`,
  `Kazi.Release.cli/1`, `Kazi.Release.burrito_main/0`) in a SEPARATE monitoring
  process that fires on a deadline. It works precisely because the observed hang
  leaves schedulers IDLE — a distinct process still gets scheduled and its timer
  still fires. On timeout it DUMPS where the main process is stuck (its current
  stacktrace, status, message-queue depth, open ports/fds, run-queue lengths) to
  stderr, turning the next specimen from an hours-long from-scratch investigation
  into an immediate "stuck in <module>.<fun>/<arity>" readout.

  It is a DIAGNOSTIC, not a fix for the (still-unexplained) root trigger.

  ## Behaviour, and why the default is dump-and-CONTINUE

  Degrade-visibly, never-worsen-a-healthy-start (the same posture as
  `Kazi.SwapDiagnosis` and the L-0035 read-model Guard): by default the watchdog
  DUMPS and lets the command keep running, so a legitimately slow startup (e.g. a
  heavily loaded box) is never turned into a failure. Opt into a hard
  `System.halt/1` on timeout with `KAZI_STARTUP_WATCHDOG_HALT=1` when you want a
  bounded, visible failure instead of a possible hang.

  The pre-BEAM Burrito extraction step (the slow part of a first invocation) runs
  BEFORE this module is ever reached, so its time is NOT counted against the
  deadline — the watchdog measures only the Elixir-side dispatch.

  ## Configuration

    * `KAZI_STARTUP_WATCHDOG_MS` — deadline in ms (default `#{30_000}`). `0`
      disables the watchdog entirely (a pure pass-through).
    * `KAZI_STARTUP_WATCHDOG_HALT` — `1`/`true` to `System.halt(#{124})` after the
      dump; anything else (default) dumps and continues.

  `opts` override the env (the test seam): `:deadline_ms`, `:halt?`, `:device`.
  """

  @default_deadline_ms 30_000
  @halt_code 124

  @doc """
  Run `fun` (a 0-arity function returning the CLI exit code) under the watchdog,
  returning `fun`'s value unchanged. With the watchdog disabled
  (`deadline_ms` `0`) this is a pure pass-through.
  """
  @spec with_watchdog((-> result), keyword()) :: result when result: term()
  def with_watchdog(fun, opts \\ []) when is_function(fun, 0) do
    deadline = deadline_ms(opts)

    if deadline > 0 do
      target = self()
      watcher = spawn(fn -> watch(target, deadline, opts) end)

      try do
        fun.()
      after
        send(watcher, :startup_complete)
      end
    else
      fun.()
    end
  end

  # Runs in the monitoring process. Because a hung startup leaves schedulers idle,
  # this process is still scheduled and its `after` timer still fires.
  defp watch(target, deadline, opts) do
    ref = Process.monitor(target)

    receive do
      :startup_complete -> :ok
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      deadline ->
        dump(target, deadline, opts)
        if halt?(opts), do: System.halt(@halt_code)
    end
  end

  # Best-effort: a diagnostic must never itself crash. Everything is wrapped so a
  # nil `Process.info` (target already exited) or a port-info race degrades to a
  # partial dump rather than killing the watchdog.
  defp dump(target, deadline, opts) do
    device = Keyword.get(opts, :device, :stderr)

    lines =
      [
        "kazi startup-watchdog: CLI startup exceeded #{deadline}ms without completing.",
        "  This is a DIAGNOSTIC (issue #1255); the command may still be running.",
        "  Set KAZI_STARTUP_WATCHDOG_MS to tune the deadline, or =0 to disable."
      ] ++ target_lines(target) ++ scheduler_lines() ++ port_lines()

    IO.puts(device, Enum.join(lines, "\n"))
  rescue
    _ -> :ok
  end

  defp target_lines(target) do
    case Process.info(target, [
           :status,
           :current_function,
           :message_queue_len,
           :current_stacktrace
         ]) do
      nil ->
        ["  main process #{inspect(target)}: already exited (no hang)."]

      info ->
        stack =
          info[:current_stacktrace]
          |> List.wrap()
          |> Enum.map(fn {m, f, a, loc} ->
            file = loc[:file]
            line = loc[:line]
            where = if file && line, do: " (#{file}:#{line})", else: ""
            "      #{inspect(m)}.#{f}/#{a}#{where}"
          end)

        [
          "  main process #{inspect(target)}: status=#{inspect(info[:status])} " <>
            "current=#{inspect(info[:current_function])} mailbox=#{info[:message_queue_len]}",
          "  stacktrace (where startup is blocked):"
        ] ++ stack
    end
  end

  defp scheduler_lines do
    run_queues = :erlang.statistics(:run_queue_lengths)

    [
      "  run_queue_lengths=#{inspect(run_queues)} " <>
        "schedulers=#{:erlang.system_info(:schedulers)} " <>
        "(all-zero run queues + a hang = an idle-scheduler receive-block, the #1255 signature)"
    ]
  rescue
    _ -> []
  end

  # Mirrors the `lsof` the #1255 investigator ran by hand: which ports/fds the VM
  # holds (sockets, files) when it is stuck.
  defp port_lines do
    ports = :erlang.ports()

    summary =
      ports
      |> Enum.map(fn port ->
        case :erlang.port_info(port, :name) do
          {:name, name} -> to_string(name)
          _ -> inspect(port)
        end
      end)

    ["  open ports (#{length(ports)}): #{inspect(summary)}"]
  rescue
    _ -> []
  end

  defp deadline_ms(opts) do
    case Keyword.fetch(opts, :deadline_ms) do
      {:ok, ms} when is_integer(ms) and ms >= 0 -> ms
      _ -> env_deadline_ms()
    end
  end

  defp env_deadline_ms do
    case System.get_env("KAZI_STARTUP_WATCHDOG_MS") do
      nil ->
        @default_deadline_ms

      raw ->
        case Integer.parse(String.trim(raw)) do
          {ms, ""} when ms >= 0 -> ms
          _ -> @default_deadline_ms
        end
    end
  end

  defp halt?(opts) do
    case Keyword.fetch(opts, :halt?) do
      {:ok, halt?} when is_boolean(halt?) -> halt?
      _ -> System.get_env("KAZI_STARTUP_WATCHDOG_HALT") in ["1", "true"]
    end
  end
end

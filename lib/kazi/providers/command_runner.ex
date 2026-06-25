defmodule Kazi.Providers.CommandRunner do
  @moduledoc """
  The shared command-execution core (T32.1b, ADR-0040 decision 1): runs a declared
  command in a target workspace and returns a tagged result, distinguishing a
  command that RAN (whatever its exit code) from one that could not run at all
  (binary missing, bad cwd) or overran a timeout.

  This is the single engine the command-runner providers fold onto:
  `Kazi.Providers.CustomScript` (the generic runner) plus the `:tests`
  (`Kazi.Providers.TestRunner`) and `:prod_log` (`Kazi.Providers.ProdLog`)
  presets, which differ only in how they DECLARE their command and map its result
  to a verdict + evidence. Centralising execution here means the `:error` vs
  `:fail` boundary (ADR-0002, ADR-0040 decision 5) — a checker that could not run
  is infra, never failing work — is enforced in exactly one place.

  ## Result

  `run/4` returns one of:

    * `{:ran, output, exit_code}` — the command ran to completion; the verdict the
      caller applies decides `:pass`/`:fail`;
    * `{:raised, message}` — the command could not be started (missing binary, bad
      cwd); the caller maps this to `:error`, never `:fail`;
    * `{:timeout, ms}` — the command overran the optional timeout and was killed;
      the caller maps this to `:error`.

  ## Options

  `opts` is forwarded verbatim to `System.cmd/3` (`:cd`, `:env`,
  `:stderr_to_stdout`, …), so each provider keeps its own capture convention (the
  `:tests`/`:prod_log` presets merge stderr into stdout; the generic runner keeps
  them separate by default). `timeout_ms` (the 4th arg) is `nil` for no timeout,
  or a positive integer to kill an overrunning command.
  """

  @typedoc "The tagged outcome of attempting to run a command."
  @type result ::
          {:ran, String.t(), integer()} | {:raised, String.t()} | {:timeout, pos_integer()}

  @doc """
  Run `cmd` with `args` under `opts`, optionally bounded by `timeout_ms`.

  With no timeout (`nil`) the command runs via `System.cmd/3` directly — the same
  boundary the providers have always used. With a positive `timeout_ms` it runs in
  a task that is brutally killed on overrun, mapping the overrun to `{:timeout,
  ms}`. A raise inside the run (missing binary / bad cwd) is captured and returned
  as `{:raised, message}` rather than crashing the caller.
  """
  @spec run(String.t(), [String.t()], keyword(), pos_integer() | nil) :: result()
  def run(cmd, args, opts, timeout_ms \\ nil)

  def run(cmd, args, opts, nil) do
    {output, exit_code} = System.cmd(cmd, args, opts)
    {:ran, output, exit_code}
  rescue
    error in [ErlangError, File.Error] -> {:raised, Exception.message(error)}
  end

  def run(cmd, args, opts, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        try do
          {:ok, System.cmd(cmd, args, opts)}
        rescue
          error in [ErlangError, File.Error] -> {:raised, Exception.message(error)}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {output, exit_code}}} -> {:ran, output, exit_code}
      {:ok, {:raised, message}} -> {:raised, message}
      _ -> {:timeout, timeout_ms}
    end
  end
end

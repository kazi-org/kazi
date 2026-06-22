defmodule Kazi.Providers.TestRunner do
  @moduledoc """
  The `:tests` predicate provider (T0.5): runs a configurable command in the
  target workspace and maps its exit code + output to a `Kazi.PredicateResult`
  (ADR-0002).

  This is the canonical objective check of Slice 0: a predicate's truth is the
  exit status of a real command run *in the workspace where the agent edits*, not
  an agent's opinion (concept §3, ADR-0002). A test runner that exits `0` is a
  `:pass`; a non-zero exit is real failing work (`:fail`); an inability to run
  the command at all (binary missing, bad config) is an `:error`, never a `:fail`
  — conflating the two would dispatch a fixer agent against an infra problem
  (`Kazi.PredicateResult`, ADR-0002).

  ## Config

  The predicate's `config` map carries the command, run via `System.cmd/3`:

    * `:cmd`  — the executable (string). Required.
    * `:args` — argument list (list of strings). Optional, defaults to `[]`.
    * `:env`  — extra environment as `{name, value}` pairs. Optional.

  A shell one-liner is `cmd: "sh", args: ["-c", "mix test"]`.

  ## Context

  `context[:workspace]` is the directory the command runs in (`cd:`), so a
  relative-path test command resolves against the same tree the harness edits
  (`Kazi.HarnessAdapter`). Defaults to the current directory when absent.

  ## Evidence

  Every result carries the proof a fixer agent needs to act (ADR-0002): the
  resolved `:cmd`, `:args`, and `:workspace`; on a completed run the `:exit`
  code and combined stdout+stderr `:output`; on a provider error a `:reason`.
  """

  @behaviour Kazi.PredicateProvider

  alias Kazi.{Predicate, PredicateResult}

  @impl true
  def evaluate(%Predicate{kind: :tests, config: config}, context) do
    workspace = context[:workspace] || File.cwd!()

    case fetch_cmd(config) do
      {:ok, cmd, args} ->
        run(cmd, args, workspace, config)

      {:error, reason} ->
        PredicateResult.error(%{reason: reason, workspace: workspace})
    end
  end

  def evaluate(%Predicate{kind: kind}, _context) do
    PredicateResult.error(%{reason: {:unsupported_kind, kind}})
  end

  # Resolves the command from config, rejecting a missing/blank :cmd before we
  # ever shell out so a malformed predicate is an :error, not a crash.
  defp fetch_cmd(config) do
    case config[:cmd] do
      cmd when is_binary(cmd) and cmd != "" ->
        {:ok, cmd, List.wrap(config[:args] || [])}

      nil ->
        {:error, :missing_cmd}

      other ->
        {:error, {:invalid_cmd, other}}
    end
  end

  # Runs the command in the workspace, capturing stdout+stderr together so the
  # evidence is the same stream a developer would read. System.cmd/3 raises only
  # when the executable cannot be found or the cwd is invalid — both are infra
  # problems, so we map them to :error rather than letting the provider crash.
  defp run(cmd, args, workspace, config) do
    opts = [cd: workspace, stderr_to_stdout: true]
    opts = if env = config[:env], do: Keyword.put(opts, :env, env), else: opts

    {output, exit_code} = System.cmd(cmd, args, opts)
    evidence = %{cmd: cmd, args: args, workspace: workspace, exit: exit_code, output: output}

    if exit_code == 0 do
      PredicateResult.pass(evidence)
    else
      PredicateResult.fail(evidence)
    end
  rescue
    error in [ErlangError, File.Error] ->
      PredicateResult.error(%{
        reason: {:cmd_unrunnable, Exception.message(error)},
        cmd: cmd,
        args: args,
        workspace: workspace
      })
  end
end

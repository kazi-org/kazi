defmodule Mix.Tasks.Kazi.Run do
  @shortdoc "Drive a goal-file to convergence (kazi run <goal-file> --workspace <path>)"

  @moduledoc """
  The `mix` entry point for kazi (T0.10, UC-004):

      mix kazi.run <goal-file> --workspace <path>

  This is the *persistent* default delivery for `kazi run`. Unlike the escript
  (`mix escript.build` → `./kazi`), this task boots the full `:kazi` OTP
  application — including the native SQLite (exqlite) NIF that an escript archive
  cannot bundle — so the read-model is created, migrated, and every iteration is
  persisted on the default path (acceptance T0.10 §3). The escript is preferred
  for ergonomics and exercises the same `Kazi.CLI` core, but degrades to
  non-persistent because NIFs cannot live inside an escript; use this task when
  persistence matters.

  Both entries share `Kazi.CLI` — argv parsing, goal loading, the run, and the
  outcome report all live there. This task only ensures the app is started and
  forwards `argv`, then exits the VM with the CLI's computed exit code (`0`
  converged, non-zero otherwise).
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    # Boot the app so Kazi.Repo (and the exqlite NIF) are up before the CLI runs;
    # the read-model then persists on the default path.
    Mix.Task.run("app.start")

    # The task name *is* the `run` command (`mix kazi.run <goal-file> …`), so the
    # remaining argv has no `run` token — prepend it so the shared `Kazi.CLI`
    # parser sees the same shape as the escript's `kazi run <goal-file> …`.
    argv
    |> prepend_run()
    |> Kazi.CLI.run()
    |> System.halt()
  end

  # `--help` must still reach the parser as a bare flag (not `run --help`), so the
  # help command resolves rather than a "run requires a goal-file" error.
  defp prepend_run(["--help" | _] = argv), do: argv
  defp prepend_run(["-h" | _] = argv), do: argv
  defp prepend_run(argv), do: ["run" | argv]
end

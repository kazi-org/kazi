defmodule Mix.Tasks.Kazi.Apply do
  @shortdoc "Drive a goal-file to convergence (kazi apply <goal-file> --workspace <path>)"

  @moduledoc """
  The `mix` entry point for kazi (T0.10, UC-004; renamed T27.1/T27.2, ADR-0032):

      mix kazi.apply <goal-file> --workspace <path>

  This is the *persistent* default delivery for `kazi apply`. Unlike the escript
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

  `mix kazi.run` is kept as a DEPRECATED ALIAS of this task (ADR-0032); it
  delegates here and prints a one-line deprecation hint to stderr.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    # Boot the app so Kazi.Repo (and the exqlite NIF) are up before the CLI runs;
    # the read-model then persists on the default path.
    Mix.Task.run("app.start")

    # The task name *is* the `apply` command (`mix kazi.apply <goal-file> …`), so
    # the remaining argv has no `apply` token — prepend it so the shared `Kazi.CLI`
    # parser sees the same shape as the escript's `kazi apply <goal-file> …`.
    argv
    |> prepend_apply()
    |> Kazi.CLI.run()
    |> System.halt()
  end

  # `--help` must still reach the parser as a bare flag (not `apply --help`), so the
  # help command resolves rather than an "apply requires a goal-file" error.
  defp prepend_apply(["--help" | _] = argv), do: argv
  defp prepend_apply(["-h" | _] = argv), do: argv
  defp prepend_apply(argv), do: ["apply" | argv]
end

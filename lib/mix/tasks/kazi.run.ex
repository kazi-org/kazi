defmodule Mix.Tasks.Kazi.Run do
  @shortdoc "Deprecated alias of `mix kazi.apply` (drive a goal-file to convergence)"

  @moduledoc """
  DEPRECATED ALIAS of `mix kazi.apply` (T27.2, ADR-0032).

      mix kazi.run <goal-file> --workspace <path>   # use `mix kazi.apply` instead

  The CLI verbs were renamed `run` → `apply` (ADR-0032). This task is kept as a
  back-compat alias through the deprecation window: it prints a one-line hint to
  stderr and delegates to `Mix.Tasks.Kazi.Apply`, which owns the real entrypoint
  (boot the app, forward argv to `Kazi.CLI`, halt with the computed exit code).
  Prefer `mix kazi.apply`; this alias is scheduled for removal in a later minor.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    # T27.2 (ADR-0032): one-line deprecation hint to STDERR (never stdout), then
    # delegate to the canonical `mix kazi.apply` task. The CLI's own stdout (incl.
    # the --json contract) is untouched.
    IO.puts(
      :stderr,
      "note: `mix kazi.run` is deprecated; use `mix kazi.apply` (removed in v0.6.0)"
    )

    Mix.Tasks.Kazi.Apply.run(argv)
  end
end

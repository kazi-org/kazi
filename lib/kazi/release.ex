defmodule Kazi.Release do
  @moduledoc """
  The `mix release` entry point for the `kazi` CLI (T6.1, ADR-0014).

  A `mix release` (built with `MIX_ENV=prod mix release`) does not use the
  escript `main/1` convention; it exposes Elixir to operators through its `eval`
  and `rpc` release commands. This module is the function those commands call so
  the release surfaces the *same* CLI as every other entry — the escript
  (`Kazi.CLI.main/1`) and `mix kazi.run` (`Mix.Tasks.Kazi.Run`). All three share
  the `Kazi.CLI` core (argv parsing, goal loading, the run, the outcome report).

  ## Why a release entry exists at all

  Unlike the escript — which cannot bundle the native exqlite NIF and therefore
  runs WITHOUT the SQLite read-model — a release bundles ERTS and compiled NIFs,
  so the released binary has the full read-model. The release is also the
  foundation Burrito (T6.2) wraps into a single self-contained per-platform
  binary.

  ## Invoking the CLI from the built release

      _build/prod/rel/kazi/bin/kazi eval 'Kazi.Release.cli(["--help"])'
      _build/prod/rel/kazi/bin/kazi eval \\
        'Kazi.Release.cli(["run", "goal.toml", "--workspace", "."])'
      _build/prod/rel/kazi/bin/kazi eval 'Kazi.Release.cli(["list-proposed"])'

  `eval` runs in a VM that has loaded the release's code but has NOT started its
  applications, so `cli/1` starts `:kazi` (bringing up `Kazi.Repo` and the
  exqlite NIF) before delegating to `Kazi.CLI.run/1`. It then halts the VM with
  the CLI's computed exit code (`0` on convergence / a recorded proposal /
  approval, non-zero otherwise) so the release composes in scripts and CI exactly
  like the escript and the Mix task.
  """

  @doc """
  Release CLI entry point. Starts the `:kazi` application (so the read-model is
  available, matching `mix kazi.run`), runs the `argv` command through the shared
  `Kazi.CLI` core, and halts the VM with the resulting exit code.

  `argv` is the list of CLI arguments the operator would pass to `kazi`, e.g.
  `["--help"]` or `["run", "goal.toml", "--workspace", "."]`.
  """
  @spec cli([String.t()]) :: no_return()
  def cli(argv) when is_list(argv) do
    # `eval` loads code but does not start applications. The help/usage path is
    # pure printing and never touches the read-model, so — like the escript — it
    # needs nothing started; booting the supervision tree (Kazi.Repo, the web
    # endpoint) for `--help` is wasted work. Every other command persists, so we
    # bring `:kazi` up first (Kazi.Repo + the bundled exqlite NIF), matching
    # `mix kazi.run`'s persistent path.
    unless help?(argv) do
      {:ok, _started} = Application.ensure_all_started(:kazi)
    end

    argv
    |> Kazi.CLI.run()
    |> System.halt()
  end

  # `--help`/`-h` resolves to the usage text without any persistence, so we skip
  # starting the app for it (mirrors the escript, which starts nothing for help).
  defp help?(argv), do: "--help" in argv or "-h" in argv
end

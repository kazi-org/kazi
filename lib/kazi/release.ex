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

  ## The Burrito binary entry (T6.2, ADR-0014)

  Burrito wraps this same release into a single self-contained per-platform
  binary (`kazi`), bundling ERTS *and* the compiled exqlite NIF — so the binary
  has the full SQLite read-model the escript can't carry. A Burrito binary does
  NOT take an `eval` argument; running it just boots the release, so the binary's
  argv (`kazi run goal.toml --workspace .`) arrives through
  `Burrito.Util.Args.argv()`, not `System.argv()`. `Kazi.Application.start/2`
  detects a Burrito run (`Burrito.Util.running_standalone?/0`, set via the
  `__BURRITO` env var) and hands control here to `burrito_main/0`, which reads
  that argv and dispatches it through the same `Kazi.CLI` core. So the binary
  behaves identically to the escript and the Mix task:

      kazi --help
      kazi run goal.toml --workspace .
      kazi list-proposed
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

    # See `Kazi.CLI.main/1` — same swap-diagnosis guard (issue #856), shared
    # across every entry point that ends in a halt.
    Kazi.SwapDiagnosis.guard(fn -> Kazi.CLI.run(argv) end)
    |> System.halt()
  end

  @doc """
  Burrito binary entry point (T6.2, ADR-0014). Called by `Kazi.Application.start/2`
  when the release is running as a Burrito-wrapped binary
  (`Burrito.Util.running_standalone?/0`).

  A Burrito binary boots the release instead of running `eval`, so the CLI args
  the operator typed (`kazi run goal.toml --workspace .`) reach the VM as
  Burrito's argv, NOT `System.argv()`. This reads them via
  `Burrito.Util.Args.argv()` and dispatches through the shared `Kazi.CLI` core,
  then halts the VM with the CLI's exit code — so the binary composes in scripts
  and CI exactly like the escript and the Mix task.

  Unlike `cli/1` (the `eval` path), this does NOT call
  `Application.ensure_all_started/1`: it is invoked from inside `start/2`, where
  the app is still starting, so waiting on its own start would deadlock. The
  shared `Kazi.CLI` core already ensures the SQLite read-model on its own
  (`Kazi.CLI.run/1` → `ensure_read_model`, which starts `Kazi.Repo` transiently
  for the migration and queries) — and because the Burrito binary bundles the
  exqlite NIF, that read-model is fully available (no escript degradation).
  """
  @spec burrito_main() :: no_return()
  def burrito_main do
    argv = Burrito.Util.Args.argv()

    Kazi.SwapDiagnosis.guard(fn -> Kazi.CLI.run(argv) end)
    |> System.halt()
  end

  # `--help`/`-h` resolves to the usage text without any persistence, so we skip
  # starting the app for it (mirrors the escript, which starts nothing for help).
  defp help?(argv), do: "--help" in argv or "-h" in argv
end

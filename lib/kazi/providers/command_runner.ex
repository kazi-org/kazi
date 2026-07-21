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

  # L-0022: a burrito-packaged kazi binary boots its own BEAM release, which sets
  # these release/ERTS locator vars in ITS OS environment (per the standard Elixir
  # release env.sh + burrito's own __BURRITO* markers). A spawned child inherits
  # them, and a nested `erl`/`mix` honours BINDIR/ROOTDIR and execs the host
  # release's `erlexec` instead of booting its own BEAM — the nested command then
  # fails opaquely (e.g. `mix test` exit 2, empty output). Every child this module
  # spawns must have this footprint scrubbed, regardless of which OS process
  # happens to be running kazi (dev shell vs. the burrito binary): the vars are
  # simply unset (never leaked) when running from source.
  @scrubbed_release_vars [
    "BINDIR",
    "ROOTDIR",
    "EMU",
    "PROGNAME",
    "RELEASE_ROOT",
    "RELEASE_NAME",
    "RELEASE_VSN",
    "RELEASE_COOKIE",
    "RELEASE_NODE",
    "RELEASE_TMP",
    "RELEASE_SYS_CONFIG",
    "RELEASE_DISTRIBUTION",
    "__BURRITO",
    "__BURRITO_BIN_PATH"
  ]

  @doc """
  Run `cmd` with `args` under `opts`, optionally bounded by `timeout_ms`.

  With no timeout (`nil`) the command runs via `System.cmd/3` directly — the same
  boundary the providers have always used. With a positive `timeout_ms` it runs in
  a task that is brutally killed on overrun, mapping the overrun to `{:timeout,
  ms}`. A raise inside the run (missing binary / bad cwd) is captured and returned
  as `{:raised, message}` rather than crashing the caller.

  Every spawned child has the host's release/ERTS footprint scrubbed from its
  environment first (L-0022); ordinary inherited env and caller-supplied `:env`
  entries are left untouched.
  """
  @spec run(String.t(), [String.t()], keyword(), pos_integer() | nil) :: result()
  def run(cmd, args, opts, timeout_ms \\ nil)

  def run(cmd, args, opts, nil) do
    {output, exit_code} = System.cmd(cmd, args, scrub_release_env(opts))
    {:ran, output, exit_code}
  rescue
    error in [ErlangError, File.Error] -> {:raised, Exception.message(error)}
  end

  def run(cmd, args, opts, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    opts = scrub_release_env(opts)

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

  # `:env` entries clear (rather than unset-and-drop) a var: System.cmd/3 only
  # overwrites/clears the keys named in `:env`, otherwise inheriting the parent's
  # full environment — so the scrub list and the caller's own `:env` simply
  # compose, with the caller's entries last so they can still win on conflict.
  defp scrub_release_env(opts) do
    scrub = Enum.map(@scrubbed_release_vars, &{&1, nil})
    caller_env = opts |> Keyword.get(:env, []) |> Enum.to_list()
    Keyword.put(opts, :env, scrub ++ scrubbed_path() ++ caller_env)
  end

  # L-0022 (PATH facet): the standard Elixir release env.sh ALSO prepends the
  # release's own `$RELEASE_ROOT/bin` and `$RELEASE_ROOT/erts-*/bin` (== $BINDIR)
  # to PATH. Those dirs hold the release BOOT SCRIPT — itself named `kazi` for the
  # burrito binary — which shadows the operator's real `kazi` launcher on the
  # child's PATH. A nested `kazi <verb>` then resolves to the boot script, which
  # only knows start/eval/version/… and rejects every CLI verb ("Unknown command
  # help"), so a `cli`/`custom_script` predicate that shells out to `kazi` can
  # never SEE the real CLI. Strip any PATH entry that lives under the host
  # RELEASE_ROOT so a spawned child resolves `kazi`/`erl`/`escript` from its own
  # toolchain instead of the release's private ERTS. Returns `[]` (leaving the
  # inherited PATH untouched) when not running from a release — the from-source
  # dev/test path, where RELEASE_ROOT is unset.
  defp scrubbed_path do
    with root when is_binary(root) and root != "" <- System.get_env("RELEASE_ROOT"),
         path when is_binary(path) <- System.get_env("PATH") do
      kept =
        path
        |> String.split(":", trim: true)
        |> Enum.reject(&under_release_root?(&1, root))

      [{"PATH", Enum.join(kept, ":")}]
    else
      _ -> []
    end
  end

  defp under_release_root?(entry, root),
    do: entry == root or String.starts_with?(entry, root <> "/")
end

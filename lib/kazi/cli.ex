defmodule Kazi.CLI do
  @moduledoc """
  The `kazi` command-line entry point (T0.10, UC-004): load a goal-file and drive
  it to convergence against an explicit target workspace.

      kazi run <goal-file> --workspace <path>

  This is the operator-facing seam over the real Slice-0 wiring. It does no
  reconciling itself — it parses argv, loads the goal via `Kazi.Goal.Loader`,
  hands it to `Kazi.Runtime.run/2`, and reports the loop's terminal outcome. The
  exit status mirrors convergence: `0` on `:converged`, non-zero otherwise, so the
  CLI composes in scripts and CI the same way the loop's own contract reads
  (concept §1, §5).

  ## Building & running (escript)

      mix escript.build          # produces the ./kazi binary
      ./kazi run priv/examples/deploy_target.toml --workspace /path/to/target
      ./kazi --help

  ## Read-model on startup

  The application supervision tree starts `Kazi.Repo` (SQLite read-model). The CLI
  boots the app and ensures that DB exists and is migrated *before* a run, so a
  fresh checkout converges on the very first invocation instead of crashing on a
  missing/locked database. If the read-model cannot be opened or migrated, the run
  degrades to `persist?: false` with a warning rather than aborting — the
  convergence loop is the product; persistence is a projection (concept §7).

  `main/1` is the escript `main_module` entry (see `mix.exs`); it terminates the
  VM with the computed exit code. The pure, testable core is `run/1`, which
  returns the exit code instead of halting so it can be exercised end-to-end.
  """

  alias Kazi.{Goal, Runtime}

  @typedoc "Process exit code: 0 on convergence, non-zero otherwise."
  @type exit_code :: non_neg_integer()

  @usage """
  kazi — drive a goal to convergence against a target workspace.

  USAGE:
      kazi run <goal-file> --workspace <path> [options]

  ARGUMENTS:
      <goal-file>            Path to a TOML goal-file (see Kazi.Goal.Loader).

  OPTIONS:
      --workspace <path>     Target workspace where edits/integrate/deploy run.
                             Falls back to the goal-file's [scope] workspace.
      --help                 Show this help and exit.

  EXAMPLES:
      kazi run priv/examples/deploy_target.toml --workspace ./fixtures/deploy-target
  """

  @doc """
  Escript entry point. Parses `argv`, runs, and halts the VM with the resulting
  exit code (`0` converged, non-zero otherwise / on error).
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    argv
    |> run()
    |> System.halt()
  end

  @doc """
  The testable core: parse `argv`, execute the command, print a human-readable
  result, and return the exit code (without halting). `IO` is used directly so
  tests can capture stdout via `ExUnit.CaptureIO`.

  `runtime_opts` are extra options merged into `Kazi.Runtime.run/2` for the
  `run` command. Production callers (the escript `main/1` and `mix kazi.run`)
  pass none; the Tier-2 boundary test uses them to point the runtime's existing
  injectable seams (`:adapter_opts`, `:integrator`, `:deploy_cmd`,
  `:deploy_params`, …) at local stubs — exactly as `Kazi.RuntimeTest` does —
  without the CLI ever naming a concrete harness/action.

  Returns `0` on convergence, a non-zero code on a stopped loop, a load/usage
  error, or an internal failure.
  """
  @spec run([String.t()], keyword()) :: exit_code()
  def run(argv, runtime_opts \\ []) when is_list(argv) and is_list(runtime_opts) do
    case parse(argv) do
      {:help, _} ->
        IO.puts(@usage)
        0

      {:run, goal_file, opts} ->
        execute_run(goal_file, opts, runtime_opts)

      {:error, message} ->
        IO.puts(:stderr, "error: #{message}\n")
        IO.puts(:stderr, @usage)
        2
    end
  end

  # =============================================================================
  # argv parsing
  # =============================================================================

  @typedoc false
  @type parsed ::
          {:help, keyword()}
          | {:run, Path.t(), keyword()}
          | {:error, String.t()}

  @doc """
  Parses `argv` into a command. Exposed for unit testing the argument boundary.

  Returns one of:

    * `{:help, opts}` — `--help` was requested.
    * `{:run, goal_file, opts}` — the `run` subcommand with its positional
      goal-file and `opts` (currently `[workspace: path | nil]`).
    * `{:error, message}` — a usage error (unknown command, missing goal-file).
  """
  @spec parse([String.t()]) :: parsed()
  def parse(argv) when is_list(argv) do
    {flags, positionals, invalid} =
      OptionParser.parse(argv,
        strict: [workspace: :string, help: :boolean],
        aliases: [h: :help]
      )

    cond do
      flags[:help] ->
        {:help, flags}

      invalid != [] ->
        {:error, "unknown option #{format_invalid(invalid)}"}

      true ->
        parse_command(positionals, flags)
    end
  end

  defp parse_command(["run", goal_file | rest], flags) do
    case rest do
      [] -> {:run, goal_file, workspace: flags[:workspace]}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  defp parse_command(["run"], _flags),
    do: {:error, "the `run` command requires a <goal-file> argument"}

  defp parse_command([other | _], _flags),
    do: {:error, "unknown command #{inspect(other)} (did you mean `run`?)"}

  defp parse_command([], _flags),
    do: {:error, "no command given (expected `run <goal-file> --workspace <path>`)"}

  defp format_invalid(invalid) do
    Enum.map_join(invalid, ", ", fn {opt, _value} -> opt end)
  end

  # =============================================================================
  # run command
  # =============================================================================

  # Boot the app + read-model, load the goal, run it, report. Returns the exit
  # code (never halts) so it stays testable.
  defp execute_run(goal_file, opts, runtime_opts) do
    persist? = ensure_read_model()

    case Goal.Loader.load(goal_file) do
      {:ok, goal} ->
        run_goal(goal, opts, persist?, runtime_opts)

      {:error, reason} ->
        IO.puts(:stderr, "error: could not load goal-file #{goal_file}: #{reason}")
        1
    end
  end

  defp run_goal(%Goal{} = goal, opts, persist?, runtime_opts) do
    workspace = opts[:workspace] || goal.scope.workspace

    # The caller's static run config; CLI-owned keys (workspace/persist?) win, and
    # an explicit :persist? in runtime_opts can still override (tests).
    run_opts =
      runtime_opts
      |> Keyword.put_new(:persist?, persist?)
      |> Keyword.put(:workspace, workspace)

    case Runtime.run(goal, run_opts) do
      {:ok, %{outcome: :converged} = result} ->
        report(goal, :converged, result)
        0

      {:ok, %{outcome: :stopped} = result} ->
        report(goal, :stopped, result)
        1

      {:error, reason} ->
        IO.puts(:stderr, "error: run failed: #{format_run_error(reason)}")
        1
    end
  end

  defp format_run_error({:unknown_provider_kinds, kinds}) do
    "goal names provider kind(s) this build can't evaluate: " <>
      Enum.map_join(kinds, ", ", &inspect/1)
  end

  defp format_run_error(:vacuous_goal),
    do:
      "goal is vacuous — every predicate already passes at t0, so there is nothing " <>
        "to build or repair. A creation/repair goal must have at least one predicate " <>
        "failing before kazi starts (concept R3); the goal is underspecified."

  defp format_run_error(:await_timeout),
    do: "the loop did not reach a terminal state within the await timeout"

  defp format_run_error(other), do: inspect(other)

  # =============================================================================
  # read-model startup (boot the app + ensure DB exists & is migrated)
  # =============================================================================

  # Boot the :kazi application (starts Kazi.Repo) and make sure the SQLite
  # read-model is created and migrated, so the default path persists iterations on
  # the very first run. Returns whether persistence is available: true when the
  # DB is ready, false (degrade gracefully, with a warning) when it can't be
  # opened/migrated.
  #
  # An escript archive cannot bundle the native exqlite NIF, so under the escript
  # the SQLite driver simply isn't loadable. We detect that cheaply up front and
  # degrade quietly, rather than letting a connection pool crash-loop loudly on a
  # missing NIF. The `mix kazi.run` task (and any real release) boots the full app
  # with the NIF present, so persistence works there on the default path.
  @spec ensure_read_model() :: boolean()
  defp ensure_read_model do
    cond do
      not sqlite_nif_available?() ->
        IO.puts(
          :stderr,
          "warning: SQLite read-model driver unavailable (running as an escript, " <>
            "which cannot bundle the native NIF); running without persistence. " <>
            "Use `mix kazi.run` for a persistent read-model."
        )

        false

      true ->
        case migrate_read_model() do
          :ok ->
            true

          {:error, reason} ->
            IO.puts(
              :stderr,
              "warning: read-model unavailable (#{inspect(reason)}); " <>
                "running without persistence"
            )

            false
        end
    end
  end

  # The exqlite driver is a NIF; if its NIF module didn't load (e.g. inside an
  # escript), no SQLite connection can be opened. Checking the exported NIF
  # function is cheap and side-effect-free — it never starts a pool.
  defp sqlite_nif_available? do
    Code.ensure_loaded?(Exqlite.Sqlite3NIF) and
      function_exported?(Exqlite.Sqlite3NIF, :open, 2)
  end

  defp migrate_read_model do
    repo = Kazi.Repo

    try do
      if started?(repo) do
        # Mix-task path: the supervision tree already started the repo (and its
        # SQLite connection creates the file on connect). Opening a *second*,
        # transient connection here to `storage_up` races the supervised pool and
        # SQLite's single writer ("database is locked"); instead just run pending
        # migrations against the live, already-connected repo.
        _ = Ecto.Migrator.run(repo, :up, all: true)
        :ok
      else
        # Escript / bare path: no supervised repo. Create the SQLite file if absent
        # (no-op if it exists), then start the repo only for the migration. With no
        # competing pool there is no lock contention.
        _ = repo.__adapter__().storage_up(repo.config())

        {:ok, _, _} =
          Ecto.Migrator.with_repo(repo, fn r ->
            Ecto.Migrator.run(r, :up, all: true)
          end)

        :ok
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp started?(repo) do
    is_pid(Process.whereis(repo)) or is_pid(GenServer.whereis(repo))
  end

  # =============================================================================
  # outcome reporting
  # =============================================================================

  defp report(%Goal{} = goal, outcome, result) do
    IO.puts(outcome_line(goal, outcome, result))
    IO.puts("iterations: #{result.iterations}")
    IO.puts("actions:    #{format_actions(result.actions)}")
    IO.puts("\npredicate vector:")
    IO.puts(format_vector(result.vector))
  end

  defp outcome_line(%Goal{id: id}, :converged, _result),
    do: "CONVERGED  goal=#{id} — every predicate is satisfied."

  defp outcome_line(%Goal{id: id}, :stopped, _result),
    do: "STOPPED    goal=#{id} — the loop stopped before converging."

  defp format_actions([]), do: "(none)"
  defp format_actions(actions), do: Enum.map_join(actions, " → ", &to_string/1)

  defp format_vector(nil), do: "  (no observation recorded)"

  defp format_vector(%Kazi.PredicateVector{results: results}) when map_size(results) == 0,
    do: "  (empty)"

  defp format_vector(%Kazi.PredicateVector{results: results}) do
    results
    |> Enum.sort_by(fn {id, _} -> to_string(id) end)
    |> Enum.map_join("\n", fn {id, result} ->
      "  #{status_glyph(result.status)} #{id}: #{result.status}"
    end)
  end

  defp status_glyph(:pass), do: "[pass]"
  defp status_glyph(:fail), do: "[fail]"
  defp status_glyph(:error), do: "[err ]"
  defp status_glyph(_), do: "[ ?  ]"
end

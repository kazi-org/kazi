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

  ## Authoring surface (T3.5c, UC-017, ADR-0011)

  The CLI also exposes the idea → acceptance-predicate authoring flow over
  `Kazi.Authoring` (T3.5a/b): a human hands kazi a prose idea, reviews the drafted
  goal, and approves it into a runnable goal.

      kazi propose "<idea>"        # draft a goal from a prose idea (status proposed)
      kazi list-proposed           # review the proposal queue
      kazi approve <proposal-ref>  # proposed → approved (then runnable by `kazi run`)
      kazi reject <proposal-ref>   # proposed → rejected (declined, kept for audit)

  These commands never reach into a running reconciliation; they only drive the
  one WRITE path the operator surfaces share (ADR-0011 §2). `propose` and `approve`
  print the `proposal-ref` an operator pipes between the steps; `approve` returns a
  goal `kazi run` then drives to convergence.

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

  alias Kazi.{Authoring, Goal, ReadModel, Runtime}
  alias Kazi.ReadModel.ProposedGoal

  @typedoc "Process exit code: 0 on convergence, non-zero otherwise."
  @type exit_code :: non_neg_integer()

  @usage """
  kazi — drive a goal to convergence against a target workspace.

  USAGE:
      kazi run <goal-file> --workspace <path> [options]
      kazi propose "<idea>" [--workspace <path>]
      kazi list-proposed [--status <proposed|approved|rejected>]
      kazi approve <proposal-ref>
      kazi reject <proposal-ref>

  ARGUMENTS:
      <goal-file>            Path to a TOML goal-file (see Kazi.Goal.Loader).
      <idea>                 A prose idea to draft into a goal of acceptance
                             predicates (T3.5a, UC-017).
      <proposal-ref>         A proposal's review handle (printed by `propose`).

  OPTIONS:
      --workspace <path>     Target workspace where edits/integrate/deploy run
                             (or, for `propose`, where the harness drafts the
                             goal). Falls back to the goal-file's [scope]
                             workspace.
      --env <name>           Deploy environment to target, e.g. staging / prod
                             (T3.3d). Selects the goal/deploy's per-env target;
                             requires the goal-file's deploy config to define an
                             `envs` map for that environment.
      --standing             Run as a STANDING (continuous/maintenance)
                             reconciler (UC-016): instead of converging and
                             stopping, hold the goal's predicates true forever,
                             re-converging whenever one drifts. Overrides the
                             goal-file's `standing` field.
      --status <state>       Filter `list-proposed` to one lifecycle state
                             (proposed / approved / rejected). Default: all.
      --help                 Show this help and exit.

  EXAMPLES:
      kazi run priv/examples/deploy_target.toml --workspace ./fixtures/deploy-target
      kazi run priv/examples/deploy_target.toml --workspace ./target --env prod
      kazi run priv/examples/standing_maintenance.toml --workspace ./svc --standing
      kazi propose "a /healthz endpoint that returns 200"
      kazi list-proposed --status proposed
      kazi approve prop-a-healthz-endpoint-3f9c1a2b4d5e
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

  `inject_opts` are extra options the CLI threads into its underlying API for the
  `run` and `propose` commands. Production callers (the escript `main/1` and
  `mix kazi.run`) pass none; the Tier-2 boundary tests use them to point the
  existing injectable seams at local stubs — exactly as `Kazi.RuntimeTest` /
  `Kazi.AuthoringTest` do — without the CLI ever naming a concrete harness/action:

    * for `run`, merged into `Kazi.Runtime.run/2` (`:adapter_opts`, `:integrator`,
      `:deploy_cmd`, `:deploy_params`, …).
    * for `propose`, merged into `Kazi.Authoring.propose/2` (`:harness`,
      `:adapter_opts`), so the e2e test drafts via a stub harness with no real
      `claude`.

  Returns `0` on success (convergence / a recorded proposal / approval), a
  non-zero code on a stopped loop, a load/usage error, or an internal failure.
  """
  @spec run([String.t()], keyword()) :: exit_code()
  def run(argv, inject_opts \\ []) when is_list(argv) and is_list(inject_opts) do
    case parse(argv) do
      {:help, _} ->
        IO.puts(@usage)
        0

      {:run, goal_file, opts} ->
        execute_run(goal_file, opts, inject_opts)

      {:propose, idea, opts} ->
        execute_propose(idea, opts, inject_opts)

      {:list_proposed, opts} ->
        execute_list_proposed(opts)

      {:approve, proposal_ref} ->
        execute_approve(proposal_ref)

      {:reject, proposal_ref} ->
        execute_reject(proposal_ref)

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
          | {:propose, String.t(), keyword()}
          | {:list_proposed, keyword()}
          | {:approve, String.t()}
          | {:reject, String.t()}
          | {:error, String.t()}

  @doc """
  Parses `argv` into a command. Exposed for unit testing the argument boundary.

  Returns one of:

    * `{:help, opts}` — `--help` was requested.
    * `{:run, goal_file, opts}` — the `run` subcommand with its positional
      goal-file and `opts`
      (`[workspace: path | nil, env: name | nil, standing: boolean | nil]`).
      `:env` is the T3.3d deploy-environment selector. `:standing` is `nil` when
      `--standing` was not given (the goal-file's own `standing` field then
      decides); `true` forces standing mode (T3.4d).
    * `{:propose, idea, opts}` — the `propose` subcommand (T3.5c) with its
      positional prose idea and `opts` (`[workspace: path | nil]`).
    * `{:list_proposed, opts}` — the `list-proposed` subcommand with `opts`
      (`[status: state | nil]`, an optional lifecycle-state filter).
    * `{:approve, proposal_ref}` / `{:reject, proposal_ref}` — the approval
      transitions over a proposal's review handle (T3.5b).
    * `{:error, message}` — a usage error (unknown command, missing goal-file).
  """
  @spec parse([String.t()]) :: parsed()
  def parse(argv) when is_list(argv) do
    {flags, positionals, invalid} =
      OptionParser.parse(argv,
        # T3.3d deploy wiring: --env picks the deploy environment (staging/prod).
        # T3.4d standing wiring: --standing authors a standing-mode run from the
        # CLI (overrides the goal-file's `standing`).
        # T3.5c authoring: --status filters the `list-proposed` review queue.
        strict: [
          workspace: :string,
          env: :string,
          standing: :boolean,
          status: :string,
          help: :boolean
        ],
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
      # T3.3d deploy wiring: carry the optional --env selector alongside workspace.
      # T3.4d standing wiring: carry the --standing flag through to the run.
      [] ->
        {:run, goal_file,
         workspace: flags[:workspace], env: flags[:env], standing: flags[:standing]}

      extra ->
        {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  defp parse_command(["run"], _flags),
    do: {:error, "the `run` command requires a <goal-file> argument"}

  # T3.5c authoring: `propose "<idea>"` drafts a goal from a prose idea. The idea
  # is a single positional argument (quote it in the shell); only --workspace is
  # carried through (where the harness drafts the goal).
  defp parse_command(["propose", idea | rest], flags) do
    case rest do
      [] -> {:propose, idea, workspace: flags[:workspace]}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  defp parse_command(["propose"], _flags),
    do: {:error, "the `propose` command requires an <idea> argument (quote it)"}

  # T3.5c authoring: `list-proposed` lists the proposal queue, optionally filtered
  # by --status (proposed / approved / rejected).
  defp parse_command(["list-proposed" | rest], flags) do
    case rest do
      [] -> {:list_proposed, status: flags[:status]}
      extra -> {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}
    end
  end

  # T3.5c authoring: `approve <proposal-ref>` / `reject <proposal-ref>` drive the
  # T3.5b transitions over a proposal's review handle.
  defp parse_command(["approve", proposal_ref | rest], _flags),
    do: approval_command(:approve, proposal_ref, rest)

  defp parse_command(["approve"], _flags),
    do: {:error, "the `approve` command requires a <proposal-ref> argument"}

  defp parse_command(["reject", proposal_ref | rest], _flags),
    do: approval_command(:reject, proposal_ref, rest)

  defp parse_command(["reject"], _flags),
    do: {:error, "the `reject` command requires a <proposal-ref> argument"}

  defp parse_command([other | _], _flags),
    do:
      {:error,
       "unknown command #{inspect(other)} (try `run`, `propose`, `list-proposed`, `approve`, or `reject`)"}

  defp parse_command([], _flags),
    do: {:error, "no command given (expected `run <goal-file> --workspace <path>`)"}

  defp approval_command(command, proposal_ref, []), do: {command, proposal_ref}

  defp approval_command(_command, _proposal_ref, extra),
    do: {:error, "unexpected argument(s): #{Enum.join(extra, " ")}"}

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
    #
    # T3.4d standing wiring: only forward `:standing` when `--standing` was
    # actually given (flag is true). When absent (nil) we leave it unset so
    # `Kazi.Runtime.run/2` falls back to the goal-file's own declared `standing`
    # field — the flag overrides the goal-file, it does not silently force it off.
    run_opts =
      runtime_opts
      |> Keyword.put_new(:persist?, persist?)
      |> Keyword.put(:workspace, workspace)
      # T3.3d deploy wiring: fold the operator's --env selection into the deploy
      # action's params, so the deepened deploy (T3.3a) selects that environment's
      # per-env target. Merged OVER any caller-supplied :deploy_params so tests
      # passing their own deploy_params keep working and an explicit --env wins.
      |> maybe_put_deploy_env(opts[:env])
      |> maybe_put_standing(opts[:standing])

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

  # T3.3d deploy wiring: merge the operator's --env into the deploy action's
  # params. No --env leaves deploy_params untouched (back-compat single-target).
  # With --env, the env atom is set on a deploy_params map merged OVER any
  # caller-supplied one, so the deepened deploy (T3.3a) selects that
  # environment's per-env target from its `envs` map.
  defp maybe_put_deploy_env(run_opts, nil), do: run_opts

  defp maybe_put_deploy_env(run_opts, env) when is_binary(env) do
    deploy_params =
      run_opts
      |> Keyword.get(:deploy_params, %{})
      |> Map.put(:env, String.to_atom(env))

    Keyword.put(run_opts, :deploy_params, deploy_params)
  end

  # T3.4d standing wiring: forward `:standing` to the runtime ONLY when the
  # `--standing` flag was given (true). A nil/false flag is left unset so the
  # goal-file's declared `standing` decides (the flag overrides, never forces off).
  defp maybe_put_standing(run_opts, true), do: Keyword.put(run_opts, :standing, true)
  defp maybe_put_standing(run_opts, _), do: run_opts

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
  # authoring commands (T3.5c, UC-017): propose / list-proposed / approve / reject
  # =============================================================================
  #
  # Each drives `Kazi.Authoring` (T3.5a/b) — the one WRITE path the operator
  # surfaces share — over the read-model the loop also persists to. They need a
  # live read-model (proposals are persisted/queried), so each ensures it first
  # and refuses cleanly if it is unavailable rather than crashing.

  # `propose "<idea>"`: draft a goal from a prose idea, persist it as `proposed`,
  # and print the proposal-ref the operator approves against. `inject_opts` carries
  # the test-only `:harness`/`:adapter_opts` seam (default the real adapter), so
  # production never names a concrete harness.
  defp execute_propose(idea, opts, inject_opts) do
    with_read_model(fn ->
      propose_opts =
        inject_opts
        |> Keyword.take([:harness, :adapter_opts])
        |> Keyword.put(:workspace, opts[:workspace] || ".")

      case Authoring.propose(idea, propose_opts) do
        {:ok, draft} ->
          report_proposed(draft)
          0

        {:error, reason} ->
          IO.puts(:stderr, "error: could not propose goal: #{format_authoring_error(reason)}")
          1
      end
    end)
  end

  # `list-proposed [--status <state>]`: print the proposal queue, newest first.
  defp execute_list_proposed(opts) do
    with_read_model(fn ->
      rows = ReadModel.list_proposed_goals(list_filter(opts[:status]))
      report_proposed_list(rows, opts[:status])
      0
    end)
  end

  defp list_filter(nil), do: []
  defp list_filter(status), do: [status: status]

  # `approve <proposal-ref>`: transition proposed → approved. On success the goal
  # is now runnable by `kazi run`; we print that next step.
  defp execute_approve(proposal_ref) do
    with_read_model(fn ->
      case Authoring.approve(proposal_ref) do
        {:ok, %Goal{} = goal} ->
          IO.puts("APPROVED   proposal=#{proposal_ref} goal=#{goal.id}")
          IO.puts("The goal is now runnable: kazi run <goal-file> --workspace <path>")
          0

        {:error, reason} ->
          IO.puts(
            :stderr,
            "error: could not approve #{proposal_ref}: " <> format_authoring_error(reason)
          )

          1
      end
    end)
  end

  # `reject <proposal-ref>`: transition proposed → rejected (declined, audited).
  defp execute_reject(proposal_ref) do
    with_read_model(fn ->
      case Authoring.reject(proposal_ref) do
        {:ok, _draft} ->
          IO.puts("REJECTED   proposal=#{proposal_ref}")
          0

        {:error, reason} ->
          IO.puts(
            :stderr,
            "error: could not reject #{proposal_ref}: " <> format_authoring_error(reason)
          )

          1
      end
    end)
  end

  # The authoring commands all require a live read-model (they persist/query
  # proposals); unlike `run` they cannot degrade to no-persistence. Ensure it, run
  # the command, or refuse cleanly with exit 1 if the DB is unavailable.
  defp with_read_model(fun) do
    if ensure_read_model() do
      fun.()
    else
      IO.puts(:stderr, "error: the read-model is unavailable; authoring requires persistence")
      1
    end
  end

  defp report_proposed(draft) do
    IO.puts("PROPOSED   goal=#{draft.goal.id}")
    IO.puts("proposal:  #{draft.proposal_ref}")
    IO.puts("idea:      #{draft.idea}")
    IO.puts("\npredicates (acceptance criteria):")
    IO.puts(format_proposed_predicates(draft.goal))
    IO.puts("\nReview, then: kazi approve #{draft.proposal_ref}")
  end

  defp format_proposed_predicates(%Goal{} = goal) do
    goal
    |> Goal.all_predicates()
    |> Enum.map_join("\n", fn predicate ->
      "  - #{predicate.id} (#{predicate.kind})" <> describe_predicate(predicate)
    end)
  end

  defp describe_predicate(%{description: description})
       when is_binary(description) and description != "",
       do: ": #{description}"

  defp describe_predicate(_predicate), do: ""

  defp report_proposed_list([], status) do
    IO.puts("(no #{status_label(status)} proposals)")
  end

  defp report_proposed_list(rows, status) do
    IO.puts("#{length(rows)} #{status_label(status)} proposal(s):\n")

    Enum.each(rows, fn %ProposedGoal{} = row ->
      IO.puts("  #{row.status}\t#{row.proposal_ref}\t#{row.goal_id}")
      IO.puts("    idea: #{row.idea}")
    end)
  end

  defp status_label(nil), do: "proposed-goal"
  defp status_label(status), do: status

  defp format_authoring_error(:empty_idea), do: "the idea was blank"
  defp format_authoring_error(:not_found), do: "no proposal carries that ref"

  defp format_authoring_error({:invalid_transition, from, to}),
    do: "cannot transition a #{from} proposal to #{to}"

  defp format_authoring_error({:harness_failed, reason}),
    do: "the authoring harness could not run: #{inspect(reason)}"

  defp format_authoring_error({:invalid_proposal, reason}),
    do: "the harness produced no usable acceptance predicate (#{reason})"

  defp format_authoring_error({:invalid_goal, reason}),
    do: "the stored goal no longer loads: #{inspect(reason)}"

  defp format_authoring_error(%Ecto.Changeset{} = changeset),
    do: "could not persist the proposal: #{inspect(changeset.errors)}"

  defp format_authoring_error(other), do: inspect(other)

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
    # T3.3d deploy wiring: surface the release ref of the artifact deployed this
    # run (T3.3c tagging) so the operator sees WHAT was shipped, not just the
    # outcome. Omitted when nothing was deployed (no release ref).
    maybe_report_release(result)
    IO.puts("\npredicate vector:")
    IO.puts(format_vector(result.vector))
  end

  # Print the release ref line only when a deploy produced one this run.
  defp maybe_report_release(%{release_ref: ref}) when is_binary(ref),
    do: IO.puts("release:    #{ref}")

  defp maybe_report_release(_result), do: :ok

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

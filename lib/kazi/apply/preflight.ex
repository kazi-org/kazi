defmodule Kazi.Apply.Preflight do
  @moduledoc """
  Base-dispatchability preflight for `kazi apply` (T44.9, UC-058): before the
  FIRST harness dispatch, verify the base can actually receive the work the run
  will produce, and REFUSE with a named, actionable reason when it cannot — so a
  run does not burn a budget only to strand its converged work on a broken push
  path or an unauthenticated GitHub CLI.

  A refusal names the SPECIFIC check that failed and how to fix it, never a
  generic "preflight failed". `kazi apply --no-preflight` bypasses every check.

  Only REAL, persisted runs are preflighted — the CLI gates this on `persist?`
  (see `Kazi.CLI.with_preflight`), so an ephemeral / read-model-unavailable
  dispatch is not blocked. Stale/dead prior runs of a goal are deliberately NOT a
  concern here: worktree reaping, the orphan-detection check (issue #857), and the
  duplicate-run guard (issue #937) already own that, and a preflight duplicate
  would only preempt them.

  ## Checks (each independent; the first failure refuses)

    * **smoke** — every command-backed (`:custom_script`) predicate's declared
      `:cmd` executable resolves on `PATH`; a goal that checks a tool which is not
      installed can never converge, so refuse before dispatching. Runs regardless
      of integration mode.
    * **`gh auth`** — only when the goal's integration mode is `:pr`/`:merge`
      (the modes that talk to GitHub): `gh auth status` must succeed.
    * **push dry-run** — only when the mode pushes (`:branch`/`:pr`/`:merge`, i.e.
      not `:commit`/`:none`): `git push --dry-run` must succeed, so the landing
      step has a working push path.

  ## Injectable command seam (hermetic tests)

  There is no central injectable command module in this codebase — providers call
  `Kazi.Providers.CommandRunner` by direct reference. So this module takes its own
  seam through `opts`, defaulting to the real path:

    * `:command_runner` — a `(cmd, args, cmd_opts -> CommandRunner.result())` fun
      for the `gh`/`git` shell-outs (default: `CommandRunner.run/4` with a bounded
      timeout). Tests pass a fake that returns a canned tagged result.

  `check/2` is pure control-flow over that seam; rendering the refusal (JSON vs
  stderr, exit code) is the CLI's job.
  """

  alias Kazi.Goal
  alias Kazi.Predicate
  alias Kazi.Providers.CommandRunner

  @typedoc "A named refusal: which check failed and the actionable message."
  @type refusal :: %{check: atom(), message: String.t()}
  @type result :: :ok | {:refuse, refusal()}

  # Modes that authenticate to / push to GitHub. `:commit`/`:none` do neither.
  @gh_auth_modes [:pr, :merge]
  @pushing_modes [:branch, :pr, :merge]

  # A hung `gh`/`git` must not hang the CLI before it even dispatches.
  @cmd_timeout_ms 15_000

  @doc """
  Runs the preflight checks for `goal` and returns `:ok` when the base is
  dispatchable, or `{:refuse, %{check: ..., message: ...}}` on the first failure.

  `opts` is the apply run's option keyword list; it supplies `:workspace` and the
  `:command_runner` seam.
  """
  @spec check(Goal.t(), keyword()) :: result()
  def check(%Goal{} = goal, opts) do
    with :ok <- check_smoke(goal, opts),
         :ok <- check_gh_auth(goal, opts),
         :ok <- check_push(goal, opts) do
      :ok
    end
  end

  # --- smoke (command-backed predicates' tools are installed) ----------------

  defp check_smoke(%Goal{predicates: predicates}, _opts) do
    predicates
    |> Enum.reduce_while(:ok, fn predicate, :ok ->
      case smoke_cmd(predicate) do
        nil ->
          {:cont, :ok}

        cmd ->
          if resolvable?(cmd) do
            {:cont, :ok}
          else
            {:halt, {:refuse, %{check: :smoke, message: smoke_message(predicate, cmd)}}}
          end
      end
    end)
  end

  defp smoke_cmd(%Predicate{kind: :custom_script, config: config}) when is_map(config) do
    case config[:cmd] do
      cmd when is_binary(cmd) and cmd != "" -> cmd
      _ -> nil
    end
  end

  defp smoke_cmd(_predicate), do: nil

  # A path-ish cmd must exist as a file; a bare name must resolve on PATH.
  defp resolvable?(cmd) do
    if String.contains?(cmd, "/") do
      File.exists?(Path.expand(cmd))
    else
      System.find_executable(cmd) != nil
    end
  end

  defp smoke_message(%Predicate{id: id}, cmd) do
    "kazi apply preflight: predicate #{inspect(id)} runs `#{cmd}`, but that command " <>
      "is not installed / not on PATH — the goal can never converge because its own " <>
      "checker cannot run. Install it, or pass --no-preflight to skip."
  end

  # --- gh auth ---------------------------------------------------------------

  defp check_gh_auth(%Goal{integration: %{mode: mode}}, opts) when mode in @gh_auth_modes do
    case run_cmd(opts, "gh", ["auth", "status"], []) do
      {:ran, _out, 0} ->
        :ok

      {:ran, out, code} ->
        refuse(
          :gh_auth,
          "kazi apply preflight: `gh auth status` failed (exit #{code}); integration " <>
            "mode #{inspect(mode)} needs an authenticated GitHub CLI to open/merge the " <>
            "PR. Run `gh auth login`, or pass --no-preflight to skip." <> detail(out)
        )

      {:raised, message} ->
        refuse(
          :gh_auth,
          "kazi apply preflight: could not run `gh auth status` (#{message}); integration " <>
            "mode #{inspect(mode)} needs the GitHub CLI. Install `gh` and run " <>
            "`gh auth login`, or pass --no-preflight to skip."
        )

      {:timeout, ms} ->
        refuse(
          :gh_auth,
          "kazi apply preflight: `gh auth status` timed out after #{ms}ms; integration " <>
            "mode #{inspect(mode)} needs an authenticated GitHub CLI. Check `gh`, or pass " <>
            "--no-preflight to skip."
        )
    end
  end

  defp check_gh_auth(%Goal{}, _opts), do: :ok

  # --- push dry-run ----------------------------------------------------------

  defp check_push(%Goal{integration: %{mode: mode} = integration} = goal, opts)
       when mode in @pushing_modes do
    workspace = opts[:workspace] || goal.scope.workspace

    target =
      if is_binary(integration.branch), do: " (target branch #{integration.branch})", else: ""

    case run_cmd(opts, "git", ["-C", workspace, "push", "--dry-run"],
           env: non_interactive_git_env()
         ) do
      {:ran, _out, 0} ->
        :ok

      {:ran, out, code} ->
        refuse(
          :push,
          "kazi apply preflight: `git push --dry-run` failed (exit #{code}) for workspace " <>
            "#{workspace}#{target}; integration mode #{inspect(mode)} pushes converged work, " <>
            "so a broken push path would strand it. Fix the remote/credentials, or pass " <>
            "--no-preflight to skip." <> detail(out)
        )

      {:raised, message} ->
        refuse(
          :push,
          "kazi apply preflight: could not run `git push --dry-run` (#{message}) for workspace " <>
            "#{workspace}#{target}; integration mode #{inspect(mode)} pushes. Check git is " <>
            "installed and the workspace is a repo, or pass --no-preflight to skip."
        )

      {:timeout, ms} ->
        refuse(
          :push,
          "kazi apply preflight: `git push --dry-run` timed out after #{ms}ms for workspace " <>
            "#{workspace}#{target}; integration mode #{inspect(mode)} pushes. Check the remote, " <>
            "or pass --no-preflight to skip."
        )
    end
  end

  defp check_push(%Goal{}, _opts), do: :ok

  # --- helpers ---------------------------------------------------------------

  defp run_cmd(opts, cmd, args, cmd_opts) do
    runner = opts[:command_runner] || (&default_runner/3)
    runner.(cmd, args, cmd_opts)
  end

  defp default_runner(cmd, args, cmd_opts) do
    CommandRunner.run(cmd, args, cmd_opts, @cmd_timeout_ms)
  end

  # A preflight push probe must FAIL FAST on a remote that needs credentials,
  # never sit on a stdin prompt: disable git's terminal / askpass / credential
  # prompts so `git push --dry-run` errors out instead of blocking.
  defp non_interactive_git_env do
    [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_ASKPASS", "echo"},
      {"GCM_INTERACTIVE", "never"}
    ]
  end

  defp refuse(check, message), do: {:refuse, %{check: check, message: message}}

  # A short, single-line tail of command output for the refusal — enough to
  # orient without dumping a wall of stderr.
  defp detail(output) do
    case output |> String.split("\n", trim: true) |> List.first() do
      nil -> ""
      line -> " Detail: #{String.slice(line, 0, 200)}"
    end
  end
end

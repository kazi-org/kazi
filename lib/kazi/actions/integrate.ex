defmodule Kazi.Actions.Integrate do
  @moduledoc """
  Land a converged fix in the target workspace (T0.10a, UC-020).

  This is the `:integrate` reconcile action (concept §5, `Kazi.Action`): once the
  loop has produced a converged change in the workspace's working tree (or on a
  branch), Integrate **ships it** — branch → commit → push → open PR →
  rebase-merge to the default branch.

  ## House rule: rebase-and-merge

  Merges use **rebase-and-merge** — never squash, never a merge commit. The real
  default merger (`gh pr merge --rebase`) honours this; a custom merger seam must
  too.

  ## The remote seam (`:integrator`)

  The remote-dependent steps — opening the PR and merging it — are isolated behind
  an injectable **integrator** so tests never touch GitHub. The local git steps
  (branch/commit/push to whatever `origin` is configured, including a local bare
  repo) are always real.

  The default integrator (`Kazi.Actions.Integrate.GhIntegrator`) is a *real*
  implementation using the `gh` CLI — this is a design seam, not a stub. Tests
  pass their own integrator (a local merge or a recording stub) via the action's
  `context` or `params`:

      ctx = %{workspace: "/path/to/repo", integrator: &MyTest.integrate/2}
      Kazi.Actions.Integrate.execute(action, ctx)

  An integrator is `fun(remote_request, opts) :: {:ok, map()} | {:error, term()}`
  where `remote_request` describes the branch, base, title and body to land. It
  must open the PR and rebase-merge it, returning a map with at least the keys
  the loop records as evidence (`:pr`, `:merge_commit`).

  ## Result

  On success `{:ok, result}` where `result` carries useful refs:

    * `:branch`        — the branch the fix was committed to;
    * `:commit`        — the local commit SHA that was pushed;
    * `:pr`            — the PR number (or identifier) the integrator opened;
    * `:merge_commit`  — the resulting merge commit on the default branch;
    * `:base`          — the default branch the change landed on.

  On failure `{:error, reason}` — e.g. `{:error, {:push_failed, output}}` — so the
  loop can decide its next action rather than crashing.
  """

  @behaviour Kazi.Action

  alias Kazi.Action

  @typedoc """
  The request handed to the integrator seam to open + merge a PR. The local git
  work is already done (branch pushed); the integrator only needs the remote bits.
  """
  @type remote_request :: %{
          workspace: String.t(),
          branch: String.t(),
          base: String.t(),
          title: String.t(),
          body: String.t()
        }

  @typedoc """
  A function that opens a PR for the pushed branch and rebase-merges it, returning
  refs (`:pr`, `:merge_commit`). Injected via context/params so tests don't hit
  GitHub; defaults to the real `gh`-based integrator.
  """
  @type integrator :: (remote_request(), keyword() -> {:ok, map()} | {:error, term()})

  # Number of attempts for network-touching git operations (push). The first
  # attempt plus retries; constant backoff between them.
  @network_attempts 3
  @network_backoff_ms 500

  @doc """
  Lands the converged change in the workspace.

  Reads from `params`:

    * `:branch`  — the branch name to create/commit on
      (default: `"kazi/integrate-<timestamp>"`);
    * `:base`    — the default branch to land on (default: detected from `origin`,
      else `"main"`);
    * `:message` — the commit message (default: a generated integrate message);
    * `:title`   — the PR title (default: the first line of the commit message);
    * `:body`    — the PR body (default: a generated note).

  Reads from `context`:

    * `:workspace`  — the target repo path (required; also accepted via the
      action's `params[:workspace]` or a `%Kazi.Scope{}` under `:scope`);
    * `:integrator` — the remote seam (default: `GhIntegrator.integrate/2`).

  See the module doc for the full contract.
  """
  @impl Kazi.Action
  @spec execute(Action.t(), Action.context()) :: Action.result()
  def execute(%Action{kind: :integrate} = action, context) do
    with {:ok, workspace} <- fetch_workspace(action, context),
         {:ok, base} <- resolve_base(workspace, action.params),
         branch = resolve_branch(action.params),
         message = resolve_message(action.params, branch),
         {:ok, _} <- create_branch(workspace, branch),
         :ok <- stage_all(workspace),
         {:ok, commit} <- commit(workspace, message),
         {:ok, _} <- push(workspace, branch),
         {:ok, remote} <-
           run_integrator(context, %{
             workspace: workspace,
             branch: branch,
             base: base,
             title: resolve_title(action.params, message),
             body: resolve_body(action.params, branch, base)
           }) do
      {:ok,
       remote
       |> Map.put_new(:branch, branch)
       |> Map.put_new(:commit, commit)
       |> Map.put_new(:base, base)}
    end
  end

  def execute(%Action{kind: kind}, _context), do: {:error, {:unsupported_kind, kind}}

  # --- workspace / params resolution -------------------------------------------

  defp fetch_workspace(action, context) do
    workspace =
      action.params[:workspace] ||
        context[:workspace] ||
        get_in(context, [:scope, Access.key(:workspace)])

    case workspace do
      ws when is_binary(ws) and ws != "" -> {:ok, ws}
      _ -> {:error, :missing_workspace}
    end
  end

  defp resolve_branch(params) do
    case params[:branch] do
      b when is_binary(b) and b != "" -> b
      _ -> "kazi/integrate-#{System.system_time(:second)}"
    end
  end

  defp resolve_message(params, branch) do
    case params[:message] do
      m when is_binary(m) and m != "" -> m
      _ -> "fix: land converged change (#{branch})"
    end
  end

  defp resolve_title(params, message) do
    case params[:title] do
      t when is_binary(t) and t != "" -> t
      _ -> message |> String.split("\n", parts: 2) |> hd()
    end
  end

  defp resolve_body(params, branch, base) do
    case params[:body] do
      b when is_binary(b) and b != "" ->
        b

      _ ->
        "Converged change landed by kazi integrate action.\n\nBranch `#{branch}` → `#{base}` (rebase-merge)."
    end
  end

  # Detect the default branch from the remote; fall back to params, then "main".
  defp resolve_base(workspace, params) do
    cond do
      is_binary(params[:base]) and params[:base] != "" ->
        {:ok, params[:base]}

      true ->
        case git(workspace, ["symbolic-ref", "refs/remotes/origin/HEAD"]) do
          {:ok, ref} ->
            {:ok, ref |> String.trim() |> String.split("/") |> List.last()}

          {:error, _} ->
            {:ok, "main"}
        end
    end
  end

  # --- git steps ----------------------------------------------------------------

  defp create_branch(workspace, branch) do
    git(workspace, ["checkout", "-B", branch])
  end

  defp stage_all(workspace) do
    case git(workspace, ["add", "-A"]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:stage_failed, reason}}
    end
  end

  defp commit(workspace, message) do
    case git(workspace, ["commit", "-m", message]) do
      {:ok, _} ->
        case git(workspace, ["rev-parse", "HEAD"]) do
          {:ok, sha} -> {:ok, String.trim(sha)}
          {:error, reason} -> {:error, {:commit_rev_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:commit_failed, reason}}
    end
  end

  # Push is network-touching: retry with backoff per the network-retry rule.
  defp push(workspace, branch) do
    case git_with_retry(
           workspace,
           ["push", "--set-upstream", "origin", branch],
           @network_attempts
         ) do
      {:ok, out} -> {:ok, out}
      {:error, reason} -> {:error, {:push_failed, reason}}
    end
  end

  # --- integrator seam ----------------------------------------------------------

  defp run_integrator(context, request) do
    integrator = context[:integrator] || (&__MODULE__.GhIntegrator.integrate/2)

    try do
      case integrator.(request, []) do
        {:ok, refs} when is_map(refs) -> {:ok, refs}
        {:error, _} = err -> err
        other -> {:error, {:bad_integrator_result, other}}
      end
    rescue
      e -> {:error, {:integrator_raised, Exception.message(e)}}
    end
  end

  # --- System.cmd helpers -------------------------------------------------------

  @doc false
  @spec git(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def git(workspace, args) do
    {out, status} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)

    case status do
      0 -> {:ok, out}
      _ -> {:error, String.trim(out)}
    end
  end

  defp git_with_retry(workspace, args, attempts) when attempts >= 1 do
    case git(workspace, args) do
      {:ok, _} = ok ->
        ok

      {:error, _} = err when attempts == 1 ->
        err

      {:error, _} ->
        Process.sleep(@network_backoff_ms)
        git_with_retry(workspace, args, attempts - 1)
    end
  end

  defmodule GhIntegrator do
    @moduledoc """
    The **real** default integrator: opens a PR and rebase-merges it with the
    `gh` CLI. This is a production implementation, not a stub — the seam exists so
    tests can substitute a local merge, not because the default is fake.

    Honours the house rule: `gh pr merge --rebase` (never squash, never a merge
    commit).
    """

    @network_attempts 3
    @network_backoff_ms 500

    @doc """
    Opens a PR for `request.branch` against `request.base` and rebase-merges it.

    Returns `{:ok, %{pr: number, merge_commit: sha}}` or `{:error, reason}`.
    """
    @spec integrate(Kazi.Actions.Integrate.remote_request(), keyword()) ::
            {:ok, map()} | {:error, term()}
    def integrate(request, _opts) do
      with {:ok, _} <- open_pr(request),
           {:ok, number} <- pr_number(request),
           {:ok, _} <- merge_pr(request, number),
           {:ok, merge_commit} <- merge_commit(request) do
        {:ok, %{pr: number, merge_commit: merge_commit}}
      end
    end

    defp open_pr(request) do
      args = [
        "pr",
        "create",
        "--base",
        request.base,
        "--head",
        request.branch,
        "--title",
        request.title,
        "--body",
        request.body
      ]

      case gh_with_retry(request.workspace, args, @network_attempts) do
        {:ok, out} -> {:ok, out}
        {:error, reason} -> {:error, {:pr_create_failed, reason}}
      end
    end

    defp pr_number(request) do
      args = ["pr", "view", request.branch, "--json", "number", "--jq", ".number"]

      case gh_with_retry(request.workspace, args, @network_attempts) do
        {:ok, out} ->
          case Integer.parse(String.trim(out)) do
            {n, _} -> {:ok, n}
            :error -> {:error, {:pr_number_unparseable, String.trim(out)}}
          end

        {:error, reason} ->
          {:error, {:pr_view_failed, reason}}
      end
    end

    # House rule: rebase-and-merge, delete the branch after.
    defp merge_pr(request, number) do
      args = ["pr", "merge", to_string(number), "--rebase", "--delete-branch"]

      case gh_with_retry(request.workspace, args, @network_attempts) do
        {:ok, out} -> {:ok, out}
        {:error, reason} -> {:error, {:pr_merge_failed, reason}}
      end
    end

    defp merge_commit(request) do
      case System.cmd("git", ["rev-parse", "origin/#{request.base}"],
             cd: request.workspace,
             stderr_to_stdout: true
           ) do
        {out, 0} -> {:ok, String.trim(out)}
        {out, _} -> {:error, {:merge_commit_failed, String.trim(out)}}
      end
    end

    defp gh(workspace, args) do
      {out, status} = System.cmd("gh", args, cd: workspace, stderr_to_stdout: true)

      case status do
        0 -> {:ok, out}
        _ -> {:error, String.trim(out)}
      end
    end

    defp gh_with_retry(workspace, args, attempts) when attempts >= 1 do
      case gh(workspace, args) do
        {:ok, _} = ok ->
          ok

        {:error, _} = err when attempts == 1 ->
          err

        {:error, _} ->
          Process.sleep(@network_backoff_ms)
          gh_with_retry(workspace, args, attempts - 1)
      end
    end
  end
end

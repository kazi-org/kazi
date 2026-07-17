defmodule Kazi.Actions.Integrate do
  @moduledoc """
  Land a converged fix in the target workspace (T0.10a, UC-020).

  This is the `:integrate` reconcile action (concept §5, `Kazi.Action`): once the
  loop has produced a converged change in the workspace's working tree (or on a
  branch), Integrate **ships it** — push → open PR → rebase-merge to the default
  branch.

  ## Two paths: verifies-then-ships vs legacy bulk-commit (T44.3, ADR-0055)

  How Integrate treats the working tree depends on whether the goal declares an
  `[integration]` landing block:

    * **`[integration]` goals (mode `commit`/`branch`/`pr`/`merge`) — verifies,
      never commits.** The INNER AGENT owns its commits during the loop (the T44.2
      `landed` predicate is what gates that: clean tree + committed state). Integrate
      does NOT run `git add -A` or `git commit`. It **verifies** the branch is a
      clean, committed, non-base branch (reusing the T44.2 `landed` provider at the
      commit level), then pushes, opens the PR with an auto-generated verification
      report (the converged predicate vector + each predicate's evidence) as the
      body, and rebase-merges. A **dirty tree** at integrate time is a distinct
      `{:error, {:dirty_tree, paths}}` — NEVER a silent bulk commit — so the loop
      re-observes, the `landed` predicate fails on the dirty tree, and the agent is
      re-dispatched to commit its work.

    * **Legacy goals (no `[integration]` block, mode `:none`) — unchanged.** Keep
      the historical branch → scoped stage (`git add`) → commit → push → PR →
      rebase-merge path exactly as before, until the next major version.

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

  ## Idempotence (issue #1027)

  `execute/2` treats the workspace as **already landed** — and is a strict
  no-op — when ALL THREE hold before any branch work begins:

    1. the working tree is clean (`git status --porcelain` is empty, staged
       changes included);
    2. the current branch has an upstream (`git rev-parse @{u}` resolves);
    3. `git rev-parse HEAD` equals `git rev-parse @{u}`.

  When all three hold, no branch is created, nothing is committed or pushed,
  the integrator seam is never invoked, and the workspace is left exactly
  where it was (HEAD does not move off an already-landed branch). The result
  still carries `:branch`/`:commit`/`:base` (read from the current state) plus
  `already_landed: true`, so a caller can tell the two paths apart. If ANY
  condition fails — dirty tree, no upstream, ahead/behind — integrate proceeds
  exactly as it always has (branch → commit → push → PR → merge).

  This closes two real failure modes: a `landed` predicate pinned to
  `HEAD == @{u}` looping forever because each iteration's integrate moved HEAD
  to a fresh upstream-less branch, and — worse — a `landed` predicate checking
  "whatever branch HEAD is on" silently passing against a substituted integrate
  branch while the named task branch had zero commits.

  ## Integrate discipline (issue #819)

  A live firing of this action once committed ~1800 untracked-but-unignored
  machine-local files (agent configs, a generated graph report) onto a public
  repo's default branch via a blind `git add -A`, and merged the PR seconds
  after opening it, before CI ran. Three guardrails close that gap:

    * **Scoped staging** — when the goal declares `[scope] paths = [...]`,
      staging is restricted to tracked modifications everywhere (`git add -u`)
      plus exactly those declared paths; an untracked file elsewhere in the
      workspace is never staged, let alone committed. A goal with no declared
      scope paths keeps the prior whole-workspace behavior (backward compatible
      default) — declaring `paths` is how a goal opts into the stricter guard.
    * **CI wait** — the integrator seam now takes a `:wait_for_checks` option
      (default `true`); the default `GhIntegrator` blocks on `gh pr checks
      --watch` before merging, so a red or still-running check blocks the
      merge. Opt out per-action via `params[:wait_for_checks] = false`.
    * **Informative landing artifacts** — the default commit message and PR
      title/body always carry the goal's id/name and the list of predicates
      that converged, never a bare "land converged change".
  """

  @behaviour Kazi.Action

  alias Kazi.Action
  alias Kazi.Predicate
  alias Kazi.PredicateResult
  alias Kazi.PredicateVector
  alias Kazi.Providers.Landed
  alias Kazi.Scope

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
    with {:ok, workspace} <- fetch_workspace(action, context) do
      case already_landed(workspace) do
        {:ok, branch, commit} ->
          {:ok, base} = resolve_base(workspace, action.params)
          {:ok, %{branch: branch, commit: commit, base: base, already_landed: true}}

        :not_landed ->
          if verifies_then_ships?(context) do
            verify_then_ship(workspace, action, context)
          else
            do_integrate(workspace, action, context)
          end
      end
    end
  end

  def execute(%Action{kind: kind}, _context), do: {:error, {:unsupported_kind, kind}}

  # T44.3 (ADR-0055): a goal that declares an `[integration] mode` (commit | branch
  # | pr | merge) opts into the verifies-then-ships contract — the INNER AGENT owns
  # its commits (the T44.2 `landed` predicate gates that), so Integrate NEVER
  # bulk-commits; it verifies a clean, committed branch, then pushes/PRs/merges. A
  # goal with no `[integration]` block (mode `:none`, or no goal threaded) keeps the
  # legacy branch → `git add -A` → commit → push → PR → merge path unchanged.
  defp verifies_then_ships?(context) do
    case context[:goal] do
      %{integration: %{mode: mode}} when mode in [:commit, :branch, :pr, :merge] -> true
      _ -> false
    end
  end

  # T44.3 (ADR-0055): verify-then-ship for `[integration]` goals. No `git add -A`,
  # no commit — the agent already committed its own work. A DIRTY tree here is a
  # distinct `{:error, {:dirty_tree, paths}}`, NEVER a silent bulk commit: the loop
  # re-observes and the (already-synthesized T44.2) `landed` predicate fails on the
  # dirty tree, re-dispatching the agent to commit rather than papering over it.
  defp verify_then_ship(workspace, action, context) do
    goal = context[:goal]
    vector = context[:vector]
    passed = passed_predicates(vector)

    with {:ok, base} <- resolve_base(workspace, action.params),
         {:ok, branch} <- verify_clean_committed(workspace, base),
         {:ok, commit} <- head_sha(workspace),
         {:ok, _} <- push(workspace, branch),
         {:ok, remote} <-
           run_integrator(
             context,
             %{
               workspace: workspace,
               branch: branch,
               base: base,
               title: resolve_title(action.params, default_subject(goal, passed)),
               body: verification_report(action.params, goal, vector, branch, base)
             },
             wait_for_checks: resolve_wait_for_checks(action.params)
           ) do
      {:ok,
       remote
       |> Map.put_new(:branch, branch)
       |> Map.put_new(:commit, commit)
       |> Map.put_new(:base, base)}
    end
  end

  # Reuse the T44.2 `landed` provider (commit-level: clean tree + committed on a
  # non-base branch) as the ship precondition rather than duplicating the
  # clean-tree check. A `:pass` yields the branch to push; a dirty tree is the
  # distinct `:dirty_tree` error; any other not-ready state (no commit, still on
  # base) is a `:not_ready` error. The mode is pinned to `:commit` here on purpose —
  # the pr/merge state is what Integrate is ABOUT to create, so verifying against
  # the full mode would be circular.
  defp verify_clean_committed(workspace, base) do
    branch = current_branch(workspace)

    predicate =
      Predicate.new(:landed, :landed, config: %{mode: :commit, branch: branch, base: base})

    case Landed.evaluate(predicate, %{workspace: workspace}) do
      %PredicateResult{status: :pass} ->
        {:ok, branch}

      %PredicateResult{status: :fail, evidence: %{reason: :dirty_tree, dirty_paths: paths}} ->
        {:error, {:dirty_tree, paths}}

      %PredicateResult{status: :fail, evidence: evidence} ->
        {:error, {:not_ready, evidence}}

      %PredicateResult{evidence: evidence} ->
        {:error, {:verify_failed, evidence}}
    end
  end

  defp current_branch(workspace) do
    case git(workspace, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, out} -> String.trim(out)
      {:error, _} -> nil
    end
  end

  # The original branch → commit → push → PR → merge path, unchanged.
  defp do_integrate(workspace, action, context) do
    goal = context[:goal]
    passed = passed_predicates(context[:vector])

    with {:ok, base} <- resolve_base(workspace, action.params),
         branch = resolve_branch(action.params),
         message = resolve_message(action.params, branch, base, goal, passed),
         {:ok, _} <- create_branch(workspace, branch),
         :ok <- stage_all(workspace, resolve_scope(context)),
         {:ok, commit} <- commit(workspace, message),
         {:ok, _} <- push(workspace, branch),
         {:ok, remote} <-
           run_integrator(
             context,
             %{
               workspace: workspace,
               branch: branch,
               base: base,
               title: resolve_title(action.params, message),
               body: resolve_body(action.params, branch, base, goal, passed)
             },
             wait_for_checks: resolve_wait_for_checks(action.params)
           ) do
      {:ok,
       remote
       |> Map.put_new(:branch, branch)
       |> Map.put_new(:commit, commit)
       |> Map.put_new(:base, base)}
    end
  end

  # Already-landed detection (issue #1027): clean tree, current branch has an
  # upstream, and HEAD == @{u}. Returns `{:ok, branch, head_sha}` when all
  # three hold, `:not_landed` otherwise (any git command failing — e.g. no
  # upstream configured — falls through to :not_landed, never an error).
  defp already_landed(workspace) do
    with {:ok, status} <- git(workspace, ["status", "--porcelain"]),
         true <- String.trim(status) == "",
         {:ok, branch} <- git(workspace, ["rev-parse", "--abbrev-ref", "HEAD"]),
         {:ok, head} <- git(workspace, ["rev-parse", "HEAD"]),
         {:ok, upstream} <- git(workspace, ["rev-parse", "@{u}"]),
         true <- String.trim(head) == String.trim(upstream) do
      {:ok, String.trim(branch), String.trim(head)}
    else
      _ -> :not_landed
    end
  end

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

  defp resolve_message(params, branch, base, goal, passed) do
    case params[:message] do
      m when is_binary(m) and m != "" -> m
      _ -> default_message(branch, base, goal, passed)
    end
  end

  defp resolve_title(params, message) do
    case params[:title] do
      t when is_binary(t) and t != "" -> t
      _ -> message |> String.split("\n", parts: 2) |> hd()
    end
  end

  defp resolve_body(params, branch, base, goal, passed) do
    case params[:body] do
      b when is_binary(b) and b != "" ->
        b

      _ ->
        "Converged change for #{goal_ref(goal)} (#{goal_name(goal)}) landed by kazi integrate.\n\n" <>
          "Converged predicates: #{predicate_list(passed)}\n\n" <>
          "Branch `#{branch}` → `#{base}` (rebase-merge)."
    end
  end

  # T44.3 (ADR-0055): the verifies-then-ships PR body — an auto-generated
  # verification report carrying the converged predicate vector + each predicate's
  # evidence, so the PR itself shows WHY kazi considers the goal met. An explicit
  # `params[:body]` overrides it verbatim.
  defp verification_report(params, goal, vector, branch, base) do
    case params[:body] do
      b when is_binary(b) and b != "" ->
        b

      _ ->
        """
        ## kazi verification report

        Goal `#{goal_ref(goal)}` (#{goal_name(goal)}) converged; landing verified — clean tree, committed on `#{branch}`.

        Branch `#{branch}` → `#{base}` — **rebase-merge** (never squash, never a merge commit).

        ### Predicate vector

        #{render_vector(vector)}
        """
    end
  end

  # Render the whole converged vector as a checklist, id-sorted for determinism,
  # each predicate's evidence inlined (the "iteration evidence" the PR body carries).
  defp render_vector(%PredicateVector{results: results}) when map_size(results) > 0 do
    results
    |> Enum.sort_by(fn {id, _} -> to_string(id) end)
    |> Enum.map_join("\n", fn {id, %PredicateResult{status: status} = result} ->
      "- #{status_mark(status)} `#{id}` — #{status}#{evidence_suffix(result)}"
    end)
  end

  defp render_vector(_), do: "_(no predicate vector recorded)_"

  defp status_mark(:pass), do: "[x]"
  defp status_mark(_), do: "[ ]"

  defp evidence_suffix(%PredicateResult{evidence: evidence}) when map_size(evidence) > 0 do
    summary =
      evidence
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{evidence_value(v)}" end)

    " (#{summary})"
  end

  defp evidence_suffix(_), do: ""

  # Compact, single-line evidence values — a long list/string is truncated so the
  # PR body stays readable.
  defp evidence_value(v) when is_binary(v), do: truncate(v)
  defp evidence_value(v) when is_list(v), do: truncate(Enum.map_join(v, ", ", &to_string/1))
  defp evidence_value(v), do: truncate(inspect(v))

  defp truncate(str) do
    if String.length(str) > 120, do: String.slice(str, 0, 117) <> "...", else: str
  end

  # Whether to block on required CI checks before merging (issue #819). Default
  # ON; a goal opts out explicitly via `params[:wait_for_checks] = false`.
  defp resolve_wait_for_checks(params) do
    case params[:wait_for_checks] do
      false -> false
      _ -> true
    end
  end

  # The default commit subject/body: always carries the goal id/name and the
  # predicates that converged (issue #819) — never a bare "land converged
  # change".
  defp default_message(branch, base, goal, passed) do
    default_subject(goal, passed) <>
      "\n\n" <>
      "Converged predicates: #{predicate_list(passed)}\n\n" <>
      "Branch `#{branch}` → `#{base}` (rebase-merge)."
  end

  defp default_subject(goal, passed) do
    "integrate(#{goal_ref(goal)}): #{goal_name(goal)} [#{predicate_list(passed)}]"
  end

  defp goal_ref(%{id: id}) when is_binary(id) and id != "", do: id
  defp goal_ref(_), do: "unknown-goal"

  defp goal_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp goal_name(%{id: id}) when is_binary(id) and id != "", do: id
  defp goal_name(_), do: "converged change"

  defp predicate_list([]), do: "(none recorded)"
  defp predicate_list(ids), do: Enum.join(ids, ", ")

  # The predicate ids whose result is `:pass` — the "what converged" summary
  # (issue #819). `nil` (no vector threaded, e.g. a bare unit test) yields none.
  defp passed_predicates(%PredicateVector{results: results}) do
    for {id, %PredicateResult{status: :pass}} <- results, do: id
  end

  defp passed_predicates(_), do: []

  # The goal's declared scope, from wherever the caller threads it — the loop's
  # `action_context/2` sets `context[:goal]` (whose `.scope` carries it); a
  # direct `context[:scope]` is honoured too. Defaults to an unscoped
  # `%Scope{}` (empty `paths`), which preserves prior whole-workspace staging.
  defp resolve_scope(context) do
    case context[:goal] do
      %{scope: %Scope{} = scope} -> scope
      _ -> context[:scope] || %Scope{}
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

  # Scoped staging (issue #819): a goal with no declared `[scope] paths` keeps
  # the prior whole-workspace `git add -A` (backward compatible default). A
  # goal that DOES declare `paths` gets the stricter guard: tracked
  # modifications are staged everywhere (`git add -u`, never introduces a new
  # untracked file), and only the explicitly declared paths are staged for
  # untracked content — an untracked file elsewhere in the workspace is never
  # swept into the commit.
  defp stage_all(workspace, %Scope{paths: []}) do
    case git(workspace, ["add", "-A"]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:stage_failed, reason}}
    end
  end

  defp stage_all(workspace, %Scope{paths: paths}) do
    with {:ok, _} <- git(workspace, ["add", "-u"]),
         {:ok, _} <- git(workspace, ["add", "--"] ++ paths) do
      :ok
    else
      {:error, reason} -> {:error, {:stage_failed, reason}}
    end
  end

  defp commit(workspace, message) do
    case git(workspace, ["commit", "-m", message]) do
      {:ok, _} ->
        head_sha(workspace)

      # T50.2 (ADR-0065 decision 2): a serial task worktree routinely arrives
      # here with its work ALREADY committed on the task branch and a clean
      # tree, so "nothing to commit" is not a failure — the pushed branch is
      # the existing HEAD.
      {:error, reason} ->
        if reason =~ ~r/nothing to commit|nothing added to commit|no changes added/i do
          head_sha(workspace)
        else
          {:error, {:commit_failed, reason}}
        end
    end
  end

  defp head_sha(workspace) do
    case git(workspace, ["rev-parse", "HEAD"]) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, reason} -> {:error, {:commit_rev_failed, reason}}
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

  defp run_integrator(context, request, opts) do
    integrator = context[:integrator] || (&__MODULE__.GhIntegrator.integrate/2)

    try do
      case integrator.(request, opts) do
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

    ## CI wait (issue #819)

    Before merging, blocks on `gh pr checks --watch` so a required check that
    is still running or has failed blocks the merge — closing the gap where a
    PR could be rebase-merged seconds after opening, before CI ran. Default
    `:wait_for_checks` is `true`; pass `wait_for_checks: false` in `opts` to
    skip the wait (e.g. a repo with no configured checks).
    """

    @network_attempts 3
    @network_backoff_ms 500

    @doc """
    Opens a PR for `request.branch` against `request.base` and rebase-merges it.

    Returns `{:ok, %{pr: number, merge_commit: sha}}` or `{:error, reason}`.
    """
    @spec integrate(Kazi.Actions.Integrate.remote_request(), keyword()) ::
            {:ok, map()} | {:error, term()}
    def integrate(request, opts) do
      with {:ok, _} <- open_pr(request),
           {:ok, number} <- pr_number(request),
           :ok <- maybe_wait_for_checks(request, number, wait_for_checks?(opts)),
           {:ok, _} <- merge_pr(request, number),
           {:ok, merge_commit} <- merge_commit(request) do
        {:ok, %{pr: number, merge_commit: merge_commit}}
      end
    end

    defp wait_for_checks?(opts) do
      case Keyword.get(opts, :wait_for_checks, true) do
        false -> false
        _ -> true
      end
    end

    defp maybe_wait_for_checks(_request, _number, false), do: :ok

    defp maybe_wait_for_checks(request, number, true) do
      args = ["pr", "checks", to_string(number), "--watch", "--fail-fast"]

      case gh(request.workspace, args) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:checks_failed, reason}}
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

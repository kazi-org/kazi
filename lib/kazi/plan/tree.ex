defmodule Kazi.Plan.Tree do
  @moduledoc """
  ADR-0086 decision 4's **interactive tree** delivery adapter (T72.4): for
  every scoped goal it projects `Kazi.Plan.Render.node/3`'s content onto the
  goal's declared scope root(s) as an `AGENTS.md` file, plus a
  `CLAUDE.md -> AGENTS.md` symlink where none exists, so a harness's own
  directory walk-up delivers the goal's acceptance contract to an agent
  working there. `kazi plan render --tree` (`Kazi.CLI`) is the one-shot
  interactive caller; `kazi apply`'s serial path (T72.4 also) calls `render_goal/3`
  the same way, before harness dispatch, against its own task worktree.

  ## Direct workspace write -- the resolved ADR-0065 §5 tension

  ADR-0065 decision 5 requires every workspace-mutating verb (naming `kazi
  plan render` explicitly) to route through the worktree indirection: create
  a kazi-owned task worktree off the workspace's HEAD (`Kazi.Scheduler.Worktree`),
  edit THERE, then integrate the committed result back onto the base via the
  existing landing path (`Kazi.Scheduler.SerialLanding` -- rebase-merge or
  push). ADR-0086 decision 4 asserts this adapter "routes through the same
  worktree indirection" while in the SAME sentence specifying that it writes
  an *ignored, untracked* file so "the operator's `cd pkg/foo` case works
  after one render" -- i.e. the file must land in the checkout the operator
  is actually standing in, not a throwaway worktree that is removed the
  moment the render command's OS process exits.

  Those two halves of decision 4 do not both hold literally, and this is a
  genuine tension, not a solved one -- flagged explicitly in T72.4's PR
  rather than silently papered over. `Kazi.Scheduler.Worktree`'s only channel
  for returning content to the base is a git COMMIT, landed by rebase-merge
  or push; its teardown DISCARDS (or, at best, salvages to a dangling
  `refs/kazi/salvage/*` ref) whatever is left uncommitted in the worktree --
  never writes it back to the caller's checkout. An `AGENTS.md` node is
  untracked BY DESIGN (ADR-0086 decision 3: "nothing it produces is ever
  committed"): there is no commit to make, and therefore nothing for the
  indirection to land. Spinning up a task worktree for this write and then
  removing it would produce a render the operator never sees at the path
  they `cd`ed into -- the opposite of decision 4's own stated purpose.

  This module resolves the tension pragmatically: `render/3` writes DIRECTLY
  into the given `workspace` argument, with no task worktree created for the
  interactive path. This is safe precisely because the artifact is add-only,
  per-checkout, and `.git/info/exclude`-local -- none of the risk ADR-0065
  guards against (an agent's shell resetting/cleaning unrelated checkout
  state) applies, because this adapter runs no agent and no shell; it only
  ever creates/overwrites files IT ITSELF generated (banner-gated, see
  below) and appends idempotent lines to a local, untracked git-config file.
  `kazi apply`'s own per-run call (`render_goal/3`, wired into
  `Kazi.CLI.run_goal_serial_at/6`) does NOT have this tension: that caller
  already isolates into its own kazi-owned task worktree before dispatch, and
  `render_goal/3` is called against THAT worktree's path -- the render still
  never touches the caller's original checkout, satisfying ADR-0065's intent
  even though the mechanism (a direct write, not a second nested worktree) is
  the same as the interactive path's.

  ## What this module does NOT do

  It never edits `.gitignore` (a TRACKED, committed file -- the wrong
  mechanism for a per-checkout-local exclusion; `.git/info/exclude` is the
  local, untracked equivalent). It never overwrites a hand-written
  `AGENTS.md` (one missing the generated banner) and never touches an
  existing `CLAUDE.md` of any kind (ADR-0086 decision 6). It does not
  implement ADR-0086 decision 5's freshness re-render-and-byte-compare
  (T72.6) or `kazi apply --cwd` (T72.7) -- both are separate, later tasks in
  the same epic (docs/plans/E72.md).
  """

  alias Kazi.Goal
  alias Kazi.Goal.Roadmap
  alias Kazi.Goal.Roadmap.Render, as: RoadmapRender
  alias Kazi.Plan.Render
  alias Kazi.PredicateVector
  alias Kazi.Runtime
  alias Kazi.Scope

  @agents_filename "AGENTS.md"
  @claude_filename "CLAUDE.md"

  @typedoc "One planned (goal, declared root, resolved directory) triple."
  @type target :: %{goal: Goal.t(), declared_root: String.t(), dir: String.t()}

  @typedoc "One delivered root's outcome."
  @type delivery :: %{
          goal_id: String.t(),
          root: String.t(),
          dir: String.t(),
          agents_path: String.t(),
          written: boolean(),
          symlink: :created | :already_present | nil,
          claude_include_hint: String.t() | nil
        }

  @typedoc false
  @type render_error ::
          {:nesting_conflict, [Scope.nesting_conflict()]}
          | {:hand_written, [String.t()]}
          | {:observe_failed, String.t(), term()}

  @doc """
  The nesting-conflict check across every member goal's `Kazi.Scope.roots/1`
  -- the SAME check `kazi plan lint` runs (ADR-0086 decision 2, T72.2),
  reused here (not reimplemented) so `--tree` refuses upfront exactly the
  way `plan lint` does.
  """
  @spec nesting_conflicts(Roadmap.t()) :: [Scope.nesting_conflict()]
  def nesting_conflicts(%Roadmap{nodes: nodes}) do
    nodes
    |> Enum.map(fn node -> {node.id, Scope.roots(node.goal.scope)} end)
    |> Scope.nesting_conflicts()
  end

  @doc """
  The `{goal, declared_root, dir}` targets a render would write, one per
  non-empty scope root -- a goal with `Kazi.Scope.roots/1 == []` renders
  nothing (ADR-0086 decision 3, "goals with no scope render nothing"), and a
  FILE-shaped root whose directory resolves to the workspace root itself is
  also skipped (`root_dir/1` -- the repo root is never a render target).
  """
  @spec targets(Roadmap.t()) :: [target()]
  def targets(%Roadmap{nodes: nodes}) do
    for node <- nodes,
        root <- Scope.roots(node.goal.scope),
        {:ok, dir} <- [root_dir(root)] do
      %{goal: node.goal, declared_root: root, dir: dir}
    end
  end

  @doc """
  Renders and delivers every scoped goal in `roadmap` under `workspace`
  (the interactive `--tree` entry point).

  Refuses upfront -- before any observe pass or write -- on a nesting
  conflict (`{:error, {:nesting_conflict, conflicts}}`). Otherwise validates
  EVERY target before writing ANY of them: a hand-written `AGENTS.md`
  (missing the generated banner) anywhere aborts the WHOLE call
  (`{:error, {:hand_written, paths}}`), naming every offending path, with
  nothing written for any goal -- matching the "writes nothing" acceptance
  contract. A goal whose predicate observe pass errors aborts the same way
  (`{:error, {:observe_failed, goal_id, reason}}`), before any write for that
  goal or any later one.

  `opts` forwards to `Kazi.Runtime.check/2` (`:providers`, `:enforcement`) --
  the same seam the CLI's `--check` mode uses, so a test can inject fixture
  providers without a real command execution.
  """
  @spec render(Roadmap.t(), Path.t(), keyword()) :: {:ok, [delivery()]} | {:error, render_error()}
  def render(%Roadmap{} = roadmap, workspace, opts \\ []) when is_binary(workspace) do
    case nesting_conflicts(roadmap) do
      [] -> render_targets(targets(roadmap), workspace, opts)
      conflicts -> {:error, {:nesting_conflict, conflicts}}
    end
  end

  @doc """
  Renders and delivers a SINGLE goal's scope roots under `workspace` -- the
  `kazi apply` call site (`Kazi.CLI.run_goal_serial_at/6`), which already has
  one goal and its own isolated worktree path, not a roadmap. No nesting
  check runs here: nesting is a property of goals seen TOGETHER (ADR-0086
  decision 2), and a single apply has no sibling goal to conflict with.
  """
  @spec render_goal(Goal.t(), Path.t(), keyword()) ::
          {:ok, [delivery()]} | {:error, render_error()}
  def render_goal(%Goal{} = goal, workspace, opts \\ []) when is_binary(workspace) do
    targets =
      for root <- Scope.roots(goal.scope),
          {:ok, dir} <- [root_dir(root)] do
        %{goal: goal, declared_root: root, dir: dir}
      end

    render_targets(targets, workspace, opts)
  end

  # --- shared pipeline: validate ALL targets, then observe + deliver -----------

  defp render_targets([], _workspace, _opts), do: {:ok, []}

  defp render_targets(targets, workspace, opts) do
    case validate_targets(targets, workspace) do
      [] -> observe_and_deliver(targets, workspace, opts)
      hand_written -> {:error, {:hand_written, hand_written}}
    end
  end

  # Every existing AGENTS.md at a target must already carry the generated
  # banner (a stale GENERATED file from a prior render -- overwritable) or be
  # absent (a fresh write). Anything else is hand-written -- collected here so
  # the WHOLE call can refuse before a single byte is written anywhere
  # (ADR-0086 decision 6 + the "writes nothing" acceptance contract).
  defp validate_targets(targets, workspace) do
    targets
    |> Enum.map(&agents_path(&1, workspace))
    |> Enum.uniq()
    |> Enum.filter(&hand_written?/1)
  end

  defp hand_written?(path) do
    case File.read(path) do
      {:ok, content} -> not String.contains?(content, RoadmapRender.banner_headline())
      {:error, _reason} -> false
    end
  end

  defp agents_path(%{dir: dir}, workspace), do: Path.join([workspace, dir, @agents_filename])

  # One observe pass PER UNIQUE GOAL (never per root -- a multi-root goal
  # shares one observed vector across its nodes, matching T72.3's "identical
  # (goal, root, observed) triples render byte-identical" contract), reusing
  # the SAME `Runtime.check/2` seam `kazi apply --check` evaluates the
  # predicate vector through -- no harness dispatch, no second observer.
  defp observe_and_deliver(targets, workspace, opts) do
    goals = targets |> Enum.map(& &1.goal) |> Enum.uniq_by(& &1.id)

    case observe_all(goals, workspace, opts) do
      {:ok, observed_by_id} ->
        {:ok, Enum.map(targets, &deliver_target(&1, workspace, observed_by_id))}

      {:error, _reason} = error ->
        error
    end
  end

  defp observe_all(goals, workspace, opts) do
    Enum.reduce_while(goals, {:ok, %{}}, fn goal, {:ok, acc} ->
      check_opts = Keyword.take(opts, [:providers, :enforcement]) ++ [workspace: workspace]

      case Runtime.check(goal, check_opts) do
        {:ok, %{vector: %PredicateVector{} = vector}} ->
          {:cont, {:ok, Map.put(acc, goal.id, vector)}}

        {:error, reason} ->
          {:halt, {:error, {:observe_failed, goal.id, reason}}}
      end
    end)
  end

  defp deliver_target(%{goal: goal, declared_root: root, dir: dir}, workspace, observed_by_id) do
    vector = Map.fetch!(observed_by_id, goal.id)
    content = Render.node(goal, root, vector)

    dir_abs = Path.join(workspace, dir)
    File.mkdir_p!(dir_abs)

    agents_path = Path.join(dir_abs, @agents_filename)
    written? = write_if_changed(agents_path, content)
    exclude_add(workspace, Path.join(dir, @agents_filename))

    {symlink, hint} = deliver_claude_md(dir_abs)

    if symlink in [:created, :already_present] do
      exclude_add(workspace, Path.join(dir, @claude_filename))
    end

    %{
      goal_id: goal.id,
      root: root,
      dir: dir,
      agents_path: agents_path,
      written: written?,
      symlink: symlink,
      claude_include_hint: hint
    }
  end

  defp write_if_changed(path, content) do
    if File.exists?(path) and match?({:ok, ^content}, File.read(path)) do
      false
    else
      File.write!(path, content)
      true
    end
  end

  # `CLAUDE.md -> AGENTS.md` symlink, created ONLY when nothing named
  # `CLAUDE.md` exists at all (ADR-0086 decision 6). `File.lstat/1` (not
  # `File.exists?/1`, which follows symlinks and would report `false` for a
  # dangling one) detects ANY existing dirent, including our own
  # previously-created symlink, so a second run recognizes it and stays a
  # no-op instead of failing on "file exists" or silently re-linking.
  defp deliver_claude_md(dir_abs) do
    claude_path = Path.join(dir_abs, @claude_filename)

    case File.lstat(claude_path) do
      {:error, :enoent} ->
        File.ln_s!(@agents_filename, claude_path)
        {:created, nil}

      {:ok, %File.Stat{type: :symlink}} ->
        if File.read_link(claude_path) == {:ok, @agents_filename} do
          {:already_present, nil}
        else
          {nil, claude_include_hint(claude_path)}
        end

      {:ok, _stat} ->
        {nil, claude_include_hint(claude_path)}
    end
  end

  defp claude_include_hint(claude_path) do
    "an existing #{claude_path} was left untouched -- add an `@#{@agents_filename}` " <>
      "include line to it so Claude Code's walk-up reads the rendered node"
  end

  # --- .git/info/exclude (never .gitignore -- ADR-0086 decision 4) ------------

  # Appends `relative_path` to the workspace's LOCAL, untracked
  # `.git/info/exclude` (resolved via `git rev-parse --git-common-dir`, which
  # is correct for both a primary checkout and a linked worktree) if it is not
  # already present -- idempotent across re-runs. A non-git workspace has no
  # such file to add to; this is a silent no-op there (mirrors the rest of
  # kazi's "a non-git workspace runs in place, unaffected" degradation), never
  # a hard failure over a delivery nicety.
  defp exclude_add(workspace, relative_path) do
    with {:ok, git_common_dir} <- git_common_dir(workspace) do
      exclude_path = Path.join([git_common_dir, "info", "exclude"])
      File.mkdir_p!(Path.dirname(exclude_path))

      existing =
        case File.read(exclude_path) do
          {:ok, content} -> content
          {:error, _reason} -> ""
        end

      lines = String.split(existing, "\n", trim: true)

      unless relative_path in lines do
        File.write!(
          exclude_path,
          existing <> ensure_trailing_newline(existing) <> relative_path <> "\n"
        )
      end
    end

    :ok
  end

  defp ensure_trailing_newline(""), do: ""

  defp ensure_trailing_newline(content),
    do: if(String.ends_with?(content, "\n"), do: "", else: "\n")

  defp git_common_dir(workspace) do
    case System.cmd("git", ["-C", workspace, "rev-parse", "--git-common-dir"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, Path.expand(String.trim(out), workspace)}
      {_out, _status} -> {:error, :not_a_git_repo}
    end
  rescue
    _ -> {:error, :not_a_git_repo}
  end

  # --- root -> directory --------------------------------------------------

  # A declared scope root is rendered VERBATIM into the node (`root` above --
  # T72.3's own contract: "root is caller-supplied context ... rendered
  # verbatim"), but `Kazi.Scope.roots/1` is not always a DIRECTORY: `[scope]`
  # `write_paths`/`paths` legitimately names a single FILE too (`Kazi.Scope`'s
  # own moduledoc cites `mix.exs`, `go.mod`, `ios/Auth.plist` as exactly this
  # shape; this repo's own fixtures use `write_paths = ["fixed.txt"]`). A
  # directory glob (`pkg/foo/**`/`pkg/foo/*`) is unambiguous -- strip the
  # suffix, the same way `Kazi.Scope`'s own (private) path normalizer does for
  # overlap comparison. A bare path whose LAST segment contains a `.` is
  # treated as FILE-shaped instead: the node renders at the file's PARENT
  # directory, never `mkdir_p!`-ing a directory onto the exact path the
  # goal's own harness is about to WRITE A FILE at (the regression this
  # guards against: a `write_paths = ["fixed.txt"]` goal converges by writing
  # `fixed.txt` at the workspace root -- if this delivery step had already
  # created a DIRECTORY named `fixed.txt` there, `echo ... > fixed.txt`
  # fails, and the goal can never converge). When a file-shaped root's parent
  # is the workspace root itself, this root is SKIPPED entirely (`:skip`) --
  # per ADR-0086's own context section, "the repo root is never a render
  # target and holds repo conventions only" -- rather than writing there.
  @spec root_dir(String.t()) :: {:ok, String.t()} | :skip
  defp root_dir(root) do
    cond do
      String.ends_with?(root, "/**") or String.ends_with?(root, "/*") ->
        {:ok, strip_glob(root)}

      file_shaped?(root) ->
        case Path.dirname(root) do
          "." -> :skip
          dir -> {:ok, dir}
        end

      true ->
        {:ok, strip_glob(root)}
    end
  end

  defp strip_glob(root) do
    root
    |> String.trim_trailing("/**")
    |> String.trim_trailing("/*")
    |> String.trim_trailing("/")
    |> case do
      "" -> "."
      dir -> dir
    end
  end

  defp file_shaped?(root) do
    root
    |> Path.basename()
    |> String.contains?(".")
  end
end

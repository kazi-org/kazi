defmodule Kazi.Plan.Freshness do
  @moduledoc """
  ADR-0086 decision 5 (T72.6): freshness enforcement for the T72.3/T72.4
  rendered `AGENTS.md` node.

  A rendered node (`Kazi.Plan.Render.node/3`, delivered into the workspace by
  `Kazi.Plan.Tree`) is a dispatch-context channel exactly like the goal-file
  and sealed inputs `Kazi.Seal` (ADR-0080) already guards: a converging agent
  has both motive and write access to hand-edit it mid-run (e.g. to make a
  currently-failing predicate's evidence section read as passing, or to
  smuggle extra "acceptance" prose a human never authored). Nothing in
  `Kazi.Plan.Tree`'s delivery loop re-checks the file after it writes it once
  before dispatch (T72.4 §"What this module does NOT do"), so without this
  module a hand-edit is invisible for the rest of the run.

  This module is deliberately shaped like `Kazi.Seal`: `deliveries/2` renders +
  delivers (T72.4's own idempotent `Tree.render_goal/3` -- best-effort,
  never raises) every one of `goal`'s scope-root nodes into `workspace`;
  `arm/1` content-hashes each delivered `AGENTS.md` path into a manifest; `verify/1`
  re-hashes the SAME paths and returns the first mismatch. The loop arms at
  t0 (`Kazi.Runtime.run/2`, alongside `Kazi.Seal.arm/3`) and re-verifies
  before every observe pass; a mismatch terminates the run `:rendered_node_drift`
  -- the SAME fatal termination class as ADR-0080's `:tampered` (a genuinely
  distinct terminal outcome, never `:converged`, never a stuck `:stopped`).

  A goal with no declared `[scope]` root, or whose render/delivery errors,
  arms an empty manifest -- freshness enforcement is then a no-op, exactly
  like a goal with `[seal] enabled = false`.

  ## `forbidden_paths/2`

  ADR-0085's `[scope].forbidden_paths` guard (`Kazi.Scope`) is extended,
  not reinvented: every path this module delivers a node to (the `AGENTS.md`
  itself, and its `CLAUDE.md` symlink when this run created one) is folded
  into the goal's EFFECTIVE `forbidden_paths` by the caller (`Kazi.Runtime.run/2`)
  BEFORE `Kazi.Scope.guard_predicates/1` synthesizes the `:scope_forbidden_paths`
  guard and `Kazi.Actions.Integrate` evaluates its own structural refusal --
  so a commit touching a rendered node fails the SAME landing guard a
  hand-authored `forbidden_paths` entry would, with no separate enforcement
  path to keep in sync.
  """

  alias Kazi.Goal
  alias Kazi.Plan.Tree

  @type digest :: binary() | :absent
  @type manifest :: %{optional(String.t()) => digest()}
  @type change :: :modified | :removed | :added

  @doc """
  Renders/delivers `goal`'s scope-root nodes into `workspace` ONCE (T72.4,
  `Tree.render_goal/3`) and returns the delivery list -- the shared input
  `arm/1` and `forbidden_paths/2` derive from, so a caller that needs both
  (`Kazi.Runtime.run/2`) never pays for (or risks observing a different
  result from) a second render/observe pass.

  Best-effort and non-fatal like `Kazi.Plan.Tree`'s own dispatch-time render
  (T72.4): a render/delivery error, or an exception raised while computing
  it, returns `[]` rather than aborting the run over a delivery nicety.
  """
  @spec deliveries(Goal.t(), Path.t() | nil) :: [Tree.delivery()]
  def deliveries(%Goal{} = goal, workspace) when is_binary(workspace) do
    case Tree.render_goal(goal, workspace) do
      {:ok, deliveries} -> deliveries
      {:error, _reason} -> []
    end
  rescue
    _ -> []
  end

  # A goal built in memory with no resolvable workspace (no `--workspace`, no
  # `[scope] workspace`) has nowhere to render/deliver a node into — a no-op,
  # not a crash, matching `Kazi.Seal.arm/3`'s own `nil` workspace no-op.
  def deliveries(%Goal{}, nil), do: []

  @doc """
  Content-hashes every delivered `AGENTS.md` path in `deliveries` (as
  returned by `deliveries/2`) into a manifest keyed by ABSOLUTE path --
  mirroring `Kazi.Seal.arm/3`'s manifest shape.
  """
  @spec arm([Tree.delivery()]) :: manifest()
  def arm(deliveries) when is_list(deliveries) do
    Map.new(deliveries, fn %{agents_path: path} -> {path, hash(path)} end)
  end

  @doc """
  Every relative path this run's rendered node(s) occupy, from `deliveries`
  (as returned by `deliveries/2`): each delivered `AGENTS.md`, plus its
  `CLAUDE.md` symlink when THIS delivery created one (an already-present
  symlink, or an existing hand-written `CLAUDE.md` this module never
  touches, is not this run's to forbid). Paths are relative to `workspace`,
  matching `[scope].forbidden_paths`'s own path shape
  (`Kazi.ScopeDiff.under_any?/2`).
  """
  @spec forbidden_paths([Tree.delivery()], Path.t() | nil) :: [String.t()]
  def forbidden_paths([], _workspace), do: []

  def forbidden_paths(deliveries, workspace) when is_list(deliveries) and is_binary(workspace) do
    deliveries
    |> Enum.flat_map(fn delivery ->
      agents_rel = Path.relative_to(delivery.agents_path, workspace)

      case delivery.symlink do
        :created ->
          [agents_rel, Path.join(delivery.dir, "CLAUDE.md")]

        _ ->
          [agents_rel]
      end
    end)
    |> Enum.uniq()
  end

  @doc """
  Re-verifies `manifest` against the current filesystem. Returns `:ok` when
  every rendered path still hashes to its armed digest, or
  `{:drift, %{path:, change:}}` for the FIRST path whose content changed
  (sorted by path for a deterministic verdict) -- `change` is `:removed`
  (was present, now absent), `:added` (was absent at arm time, now present),
  or `:modified` (bytes differ), the same vocabulary `Kazi.Seal.verify/1`
  uses.

  An empty manifest is always `:ok`.
  """
  @spec verify(manifest()) :: :ok | {:drift, %{path: String.t(), change: change()}}
  def verify(manifest) when manifest == %{}, do: :ok

  def verify(manifest) do
    manifest
    |> Enum.sort_by(fn {path, _digest} -> path end)
    |> Enum.find_value(:ok, fn {path, digest} ->
      case classify(digest, hash(path)) do
        nil -> nil
        change -> {:drift, %{path: path, change: change}}
      end
    end)
  end

  defp classify(same, same), do: nil
  defp classify(:absent, _now), do: :added
  defp classify(_t0, :absent), do: :removed
  defp classify(_t0, _now), do: :modified

  @spec hash(String.t()) :: digest()
  defp hash(path) do
    case File.read(path) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes)
      {:error, _reason} -> :absent
    end
  end
end

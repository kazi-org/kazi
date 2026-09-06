defmodule Kazi.Plan.Dag do
  @moduledoc """
  `kazi plan render --dag <fleet-dir|manifest>` (T73.4): a NEW rendering
  adapter beside `Kazi.Plan.Tree` (T72.4) and the plain markdown roadmap
  render (T45.5) -- this one projects a `Kazi.Fleet` (T50.4, ADR-0065
  decision 3) into a stable JSON document describing the fleet's DAG:
  every goal, the effective `shared_paths` set (T73.1), every edge (explicit
  and inferred-overlap, T73.2), and a per-node `render_sha256` snapshot of
  what `Kazi.Plan.Render.node/3` (T72.3) would deliver for that goal AT
  PLANNING TIME.

  ## Why a snapshot, not a live render

  The DAG document is produced once, ahead of dispatch, so an operator or a
  dispatcher can inspect the whole fleet's shape before anything runs. The
  dispatcher (a lane contract, ADR-0086's `--lane-contract`) re-renders each
  node's `AGENTS.md` at ACTUAL dispatch time against the worktree it created
  -- observed state can have moved between planning and dispatch (a sibling
  goal's earlier work converging first, etc.), so the planning-time
  `render_sha256` here is a snapshot for visibility, never a substitute for
  that later re-render/compare (T72.3's freshness check owns byte-parity at
  dispatch time). The document's `note` field says this explicitly so nothing
  downstream mistakes the snapshot for a promise of freshness.

  ## Determinism

  `Kazi.Fleet.load/1` already yields nodes in sorted filename order and edges
  in a fixed derivation order (explicit edges first, then inferred-overlap
  pairs in ascending node-index order); `shared_paths` is a sorted union.
  This module preserves that ordering end to end -- it builds its output from
  those SAME lists, in the SAME order, so two runs against an unchanged fleet
  and workspace HEAD produce byte-identical JSON (the golden-file test pins
  this).

  This module does no I/O beyond what `Kazi.Runtime.check/2` (the SAME
  observe seam `Kazi.Plan.Tree` uses) and `File.read!/1` (goal-file bytes,
  for the digest) require. It writes nothing to disk itself; `Kazi.CLI`
  owns `--out` vs. stdout.
  """

  alias Kazi.Fleet
  alias Kazi.Goal
  alias Kazi.Plan.Render
  alias Kazi.PredicateVector
  alias Kazi.Runtime
  alias Kazi.Scope

  @typedoc false
  @type dag_error :: {:observe_failed, String.t(), term()}

  @doc """
  Builds the DAG document for `fleet`, computed against `workspace` (used
  only to seed each goal's predicate observe pass -- the same seam
  `Kazi.Plan.Tree.render/3` uses; it never writes into `workspace`).

  `source_commit` is caller-supplied (`Kazi.CLI` reads it via
  `git rev-parse HEAD` against the SAME `workspace`) rather than re-derived
  here, so this module stays a pure function of already-loaded data plus one
  caller-provided string -- mirroring `Kazi.Plan.Render.node/3`'s own
  "renders are pure functions of their inputs" contract.
  """
  @spec build(Fleet.t(), String.t(), String.t()) :: {:ok, map()} | {:error, dag_error()}
  def build(%Fleet{} = fleet, source_commit, workspace)
      when is_binary(source_commit) and is_binary(workspace) do
    case render_shas(fleet.nodes, workspace) do
      {:ok, shas_by_id} ->
        {:ok,
         %{
           "source_commit" => source_commit,
           "goals" => Enum.map(fleet.nodes, &goal_entry/1),
           "shared_paths" => Fleet.effective_shared_paths(fleet),
           "nodes" => Enum.map(fleet.nodes, &node_entry(&1, shas_by_id)),
           "edges" => Enum.map(fleet.edges, &edge_entry/1),
           "note" =>
             "render_sha256 is a planning-time snapshot; the dispatcher re-renders each " <>
               "node against its own worktree at dispatch time and that later render is " <>
               "authoritative, not this one."
         }}

      {:error, _reason} = error ->
        error
    end
  end

  # --- goals[] -----------------------------------------------------------

  defp goal_entry(%Fleet.Node{id: id, file: file, goal: goal}) do
    %{
      "id" => id,
      "file" => file,
      "sha256" => file_sha256(file),
      "write_paths" => goal.scope.write_paths,
      "roots" => Scope.roots(goal.scope)
    }
  end

  defp file_sha256(file) do
    file
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # --- nodes[] -------------------------------------------------------------

  defp node_entry(%Fleet.Node{id: id}, shas_by_id) do
    %{"id" => id, "render_sha256" => Map.fetch!(shas_by_id, id)}
  end

  # One observe pass per node (mirroring `Kazi.Plan.Tree.observe_and_deliver/3`),
  # then one `Render.node/3` per declared scope root, concatenated in root
  # order and hashed -- a goal with no scope roots renders nothing, so its
  # `render_sha256` is `nil` (ADR-0086 decision 3: "goals with no scope render
  # nothing").
  defp render_shas(nodes, workspace) do
    Enum.reduce_while(nodes, {:ok, %{}}, fn %Fleet.Node{id: id, goal: goal}, {:ok, acc} ->
      case node_render_sha(goal, workspace) do
        {:ok, sha} -> {:cont, {:ok, Map.put(acc, id, sha)}}
        {:error, reason} -> {:halt, {:error, {:observe_failed, id, reason}}}
      end
    end)
  end

  defp node_render_sha(%Goal{} = goal, workspace) do
    case Scope.roots(goal.scope) do
      [] ->
        {:ok, nil}

      roots ->
        case Runtime.check(goal, workspace: workspace) do
          {:ok, %{vector: %PredicateVector{} = vector}} ->
            sha =
              roots
              |> Enum.map(&Render.node(goal, &1, vector))
              |> Enum.join()
              |> then(&:crypto.hash(:sha256, &1))
              |> Base.encode16(case: :lower)

            {:ok, sha}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # --- edges[] -------------------------------------------------------------

  defp edge_entry(%Fleet.Edge{from: from, to: to, kind: kind, overlap: overlap}) do
    %{
      "from" => from,
      "to" => to,
      "kind" => to_string(kind),
      "overlap" => Enum.map(overlap, fn {a, b} -> [a, b] end)
    }
  end
end

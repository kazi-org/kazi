defmodule Kazi.Goal.Roadmap do
  @moduledoc """
  A **roadmap** is a top-level artifact (T45.1, UC-059): a self-contained,
  DECLARATIVE DAG of goals. It is a NEW artifact type, sibling to a goal-file, in
  the same "goal loader family" — a roadmap-file references goals, a goal-file
  declares predicates.

  ## File format

  A roadmap `.toml` is a `[[goals]]` array. Each entry is one DAG NODE and
  carries:

    * `id` — REQUIRED, unique across the roadmap; the handle other entries name in
      their `needs`.
    * exactly one goal SOURCE:
      * `path = "goals/api.goal.toml"` — a goal-file path, resolved relative to
        the roadmap file's own directory (absolute paths pass through), loaded via
        `Kazi.Goal.Loader.load/1`; or
      * an inline `[goals.goal]` sub-table — a goal-file's content embedded
        verbatim, loaded via `Kazi.Goal.Loader.from_map/1` (the entry `id` fills
        in the goal's `id` when the inline table omits it).
    * `needs = ["<goal-id>", ...]` — OPTIONAL goal-to-goal edges: this node's
      predecessors. A `needs` id must name a declared entry.

  ```toml
  [[goals]]
  id = "foundation"
  path = "goals/foundation.goal.toml"

  [[goals]]
  id = "api"
  path = "goals/api.goal.toml"
  needs = ["foundation"]

  [[goals]]
  id = "ui"
  needs = ["api"]

    [goals.goal]
    id = "ui-goal"
    name = "ship the UI"
  ```

  ## Relationship to `--fleet` (ADR-0075)

  This is the goal-to-goal DAG at the ARTIFACT tier; `kazi apply --fleet`
  (ADR-0065) is the goal-to-goal DAG at the EXECUTION tier. They are structurally
  the same problem — nodes with `needs` edges, validated acyclic with resolvable
  refs — but a roadmap declares its edges CENTRALLY (`needs` in the roadmap file)
  and supports INLINE goal-sets, whereas a fleet manifest is a thin list of paths
  whose edges live DECENTRALIZED on each goal-file's `[metadata] depends_on`. This
  module reuses `Kazi.Fleet`'s DFS cycle-detection pattern rather than a fresh
  graph algorithm. See ADR-0075 for why both exist.

  ## Validation

  `load/1` rejects, NAMING the offending ref:

    * a missing/duplicate `id`;
    * an entry with neither or both of `path`/inline goal;
    * an unresolvable goal ref — a `path` that does not load, or a `needs` id with
      no matching entry;
    * a cycle — the error lists the goal ids on the cycle.
  """

  alias Kazi.Fleet
  alias Kazi.Goal
  alias Kazi.Goal.Loader

  defmodule Node do
    @moduledoc "One roadmap node: a goal, its source, and its declared `needs`."
    @type source :: {:path, Path.t()} | :inline
    @type t :: %__MODULE__{id: String.t(), source: source(), needs: [String.t()], goal: Goal.t()}
    defstruct [:id, :source, :goal, needs: []]
  end

  defmodule Edge do
    @moduledoc "One roadmap edge: `from` (a `needs` target) must precede `to`."
    @type t :: %__MODULE__{from: String.t(), to: String.t()}
    defstruct [:from, :to]
  end

  @type t :: %__MODULE__{nodes: [Node.t()], edges: [Edge.t()], path: Path.t() | nil}
  defstruct nodes: [], edges: [], path: nil

  @doc """
  Loads a roadmap from a `.toml` file. Returns `{:error, reason}` — naming the
  offending ref — for an unloadable member, an unresolvable `needs`/`path` ref, a
  duplicate id, or a cycle.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) when is_binary(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, data} <- decode_toml(path, contents),
         {:ok, roadmap} <- from_map(data, Path.dirname(path)) do
      {:ok, %{roadmap | path: path}}
    end
  end

  @doc """
  Parses an already-decoded roadmap map (string-keyed). `base_dir` resolves
  relative `path` members. Exposed for callers that obtain the map another way.
  """
  @spec from_map(map(), Path.t()) :: {:ok, t()} | {:error, String.t()}
  def from_map(data, base_dir \\ ".") when is_map(data) do
    with {:ok, entries} <- fetch_goals(data),
         {:ok, nodes} <- build_nodes(entries, base_dir),
         :ok <- validate_unique_ids(nodes),
         {:ok, edges} <- build_edges(nodes),
         :ok <- validate_acyclic(nodes, edges) do
      {:ok, %__MODULE__{nodes: nodes, edges: edges}}
    end
  end

  @doc """
  The topological frontiers over the roadmap's edges: a list of waves, each wave a
  list of node ids whose every predecessor is in an earlier wave. Pure — `load/1`
  already rejected cycles. Delegates to `Kazi.Fleet.frontiers/1`, the SAME
  goal-level layering `kazi apply --fleet --explain` prints.
  """
  @spec frontiers(t()) :: [[String.t()]]
  def frontiers(%__MODULE__{nodes: nodes, edges: edges}) do
    fleet_nodes =
      Enum.map(nodes, fn n -> %Fleet.Node{id: n.id, file: source_label(n), goal: n.goal} end)

    fleet_edges =
      Enum.map(edges, fn e -> %Fleet.Edge{from: e.from, to: e.to, kind: :explicit} end)

    Fleet.frontiers(%Fleet{nodes: fleet_nodes, edges: fleet_edges})
  end

  @doc """
  The roadmap ARTIFACT schema — the `{field, type, description}` descriptor
  `kazi schema roadmap` emits, mirroring the `docs/schemas/roadmap.md` contract.
  """
  @spec schema() :: map()
  def schema do
    %{
      artifact: "roadmap",
      title: "kazi roadmap artifact",
      description:
        "A top-level DECLARATIVE DAG of goals (T45.1, UC-059). A `.toml` with a " <>
          "[[goals]] array; each entry is one node with a unique `id`, one goal source " <>
          "(a `path` to a goal-file OR an inline [goals.goal] table), and an optional " <>
          "`needs` list of predecessor goal ids. Loaded via `kazi lint <roadmap>`; the " <>
          "loader validates unique ids, resolvable refs, and acyclicity.",
      fields: [
        %{name: "goals", type: "array<object>", description: "The DAG nodes; at least one."},
        %{
          name: "goals[].id",
          type: "string",
          description: "Required, unique node id — the `needs` handle."
        },
        %{
          name: "goals[].path",
          type: "string",
          description:
            "A goal-file path (relative to the roadmap file), loaded as this node's goal. " <>
              "Mutually exclusive with an inline goal."
        },
        %{
          name: "goals[].goal",
          type: "object",
          description:
            "An inline goal-file table (the [goals.goal] sub-table). Mutually exclusive " <>
              "with `path`; the entry `id` fills in the goal `id` when omitted."
        },
        %{
          name: "goals[].needs",
          type: "array<string>",
          description:
            "Optional predecessor goal ids. Each must name a declared entry; the graph must be acyclic."
        }
      ],
      example: %{
        "goals" => [
          %{"id" => "foundation", "path" => "goals/foundation.goal.toml"},
          %{"id" => "api", "path" => "goals/api.goal.toml", "needs" => ["foundation"]},
          %{"id" => "ui", "path" => "goals/ui.goal.toml", "needs" => ["api"]}
        ]
      }
    }
  end

  # --- decode ---

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "cannot read roadmap #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode_toml(path, contents) do
    case Toml.decode(contents) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "roadmap #{path}: malformed TOML: #{inspect(reason)}"}
    end
  end

  defp fetch_goals(data) do
    case Map.get(data, "goals") do
      [%{} | _] = entries -> {:ok, entries}
      [] -> {:error, "roadmap declares an empty [[goals]] array — at least one goal is required"}
      nil -> {:error, "roadmap is missing the required [[goals]] array"}
      _ -> {:error, "roadmap [[goals]] must be an array of tables"}
    end
  end

  # --- node loading ---

  defp build_nodes(entries, base_dir) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case build_node(entry, index, base_dir) do
        {:ok, node} -> {:cont, {:ok, [node | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp build_node(entry, index, base_dir) do
    with {:ok, id} <- fetch_entry_id(entry, index),
         {:ok, needs} <- fetch_needs(id, entry),
         {:ok, source, goal} <- load_goal(id, entry, base_dir) do
      {:ok, %Node{id: id, source: source, needs: needs, goal: goal}}
    end
  end

  defp fetch_entry_id(entry, index) do
    case Map.get(entry, "id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      nil -> {:error, "roadmap goal ##{index + 1} is missing the required key \"id\""}
      _ -> {:error, "roadmap goal ##{index + 1} \"id\" must be a non-empty string"}
    end
  end

  defp fetch_needs(id, entry) do
    case Map.get(entry, "needs") do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, "roadmap goal #{inspect(id)} \"needs\" must be a list of goal-id strings"}
        end

      _ ->
        {:error, "roadmap goal #{inspect(id)} \"needs\" must be a list of goal-id strings"}
    end
  end

  defp load_goal(id, entry, base_dir) do
    path = Map.get(entry, "path")
    inline = Map.get(entry, "goal")

    case {path, inline} do
      {p, nil} when is_binary(p) ->
        resolved = resolve_path(p, base_dir)

        case Loader.load(resolved) do
          {:ok, goal} ->
            {:ok, {:path, resolved}, goal}

          {:error, reason} ->
            {:error, "roadmap goal #{inspect(id)} references #{resolved}: #{reason}"}
        end

      {nil, %{} = table} ->
        case Loader.from_map(Map.put_new(table, "id", id)) do
          {:ok, goal} -> {:ok, :inline, goal}
          {:error, reason} -> {:error, "roadmap goal #{inspect(id)} inline goal: #{reason}"}
        end

      {nil, nil} ->
        {:error,
         "roadmap goal #{inspect(id)} declares no goal source — set `path` or an inline [goals.goal] table"}

      {_, _} ->
        {:error,
         "roadmap goal #{inspect(id)} declares BOTH `path` and an inline goal — use exactly one"}
    end
  end

  defp resolve_path(rel, base_dir) do
    if Path.type(rel) == :absolute, do: rel, else: Path.join(base_dir, rel)
  end

  # --- duplicate ids ---

  defp validate_unique_ids(nodes) do
    nodes
    |> Enum.group_by(& &1.id)
    |> Enum.find(fn {_id, group} -> length(group) > 1 end)
    |> case do
      nil -> :ok
      {id, _} -> {:error, "roadmap declares goal id #{inspect(id)} more than once"}
    end
  end

  # --- edges + ref resolution ---

  defp build_edges(nodes) do
    declared = MapSet.new(nodes, & &1.id)

    nodes
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      case Enum.find(node.needs, &(not MapSet.member?(declared, &1))) do
        nil ->
          edges = Enum.map(node.needs, fn dep -> %Edge{from: dep, to: node.id} end)
          {:cont, {:ok, edges ++ acc}}

        unknown ->
          {:halt,
           {:error,
            "roadmap goal #{inspect(node.id)} needs unknown goal id #{inspect(unknown)} " <>
              "(declared: #{declared_ids(declared)})"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp declared_ids(declared) do
    declared |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
  end

  # --- cycle detection ---
  #
  # DFS with a `finished` memo and an ancestor stack, mirroring
  # `Kazi.Fleet`'s explicit-edge cycle guard. On a back-edge the error names the
  # FULL cycle chain (every goal id on the cycle), not just the two endpoints.

  defp validate_acyclic(nodes, edges) do
    deps_by_id =
      Map.new(nodes, fn node ->
        deps = edges |> Enum.filter(&(&1.to == node.id)) |> Enum.map(& &1.from)
        {node.id, deps}
      end)

    Enum.reduce_while(nodes, {:ok, MapSet.new()}, fn node, {:ok, finished} ->
      case walk(node.id, deps_by_id, [], finished) do
        {:ok, finished} -> {:cont, {:ok, finished}}
        {:cycle, chain} -> {:halt, {:error, cycle_message(chain)}}
      end
    end)
    |> case do
      {:ok, _finished} -> :ok
      {:error, _} = error -> error
    end
  end

  defp cycle_message(chain) do
    "roadmap dependency cycle: " <> Enum.join(chain, " -> ")
  end

  defp walk(id, deps_by_id, stack, finished) do
    cond do
      MapSet.member?(finished, id) ->
        {:ok, finished}

      id in stack ->
        chain = stack |> Enum.reverse() |> Enum.drop_while(&(&1 != id))
        {:cycle, chain ++ [id]}

      true ->
        stack = [id | stack]

        deps_by_id
        |> Map.get(id, [])
        |> Enum.reduce_while({:ok, finished}, fn dep, {:ok, finished} ->
          case walk(dep, deps_by_id, stack, finished) do
            {:ok, finished} -> {:cont, {:ok, finished}}
            {:cycle, _} = cycle -> {:halt, cycle}
          end
        end)
        |> case do
          {:ok, finished} -> {:ok, MapSet.put(finished, id)}
          {:cycle, _} = cycle -> cycle
        end
    end
  end

  defp source_label(%Node{source: {:path, path}}), do: path
  defp source_label(%Node{source: :inline, id: id}), do: "inline:#{id}"
end

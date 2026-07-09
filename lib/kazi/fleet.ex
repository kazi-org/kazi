defmodule Kazi.Fleet do
  @moduledoc """
  A **fleet** is a DAG of goal-files (T50.4, ADR-0065 decision 3): the MODEL and
  DISCOVERY half of `kazi apply --fleet <dir|manifest>`. Execution is a separate
  follow-up (T50.5) — this module only loads members into nodes, computes the
  edges between them, and exposes the topological frontiers. It never dispatches
  a harness or mutates a workspace.

  ## Members

  `load/1` accepts either:

    * a DIRECTORY — every `*.goal.toml` file in it (non-recursive), loaded in
      sorted filename order;
    * a manifest `.toml` file — a `[[member]]` array of `path = "..."` entries,
      resolved relative to the manifest's own directory (absolute paths pass
      through unchanged).

  Each loaded goal-file becomes a fleet NODE, keyed by its goal id (which must be
  unique across the whole fleet — a duplicate is a load error naming both files).

  ## Edges

  Two kinds, mirroring `Kazi.Goal.DepGraph`'s `needs`-edge semantics one layer up:

    * **explicit** — a node's OPTIONAL `[metadata] depends_on = ["<goal-id>", ...]`
      key (already loaded verbatim onto `Goal.metadata` by the existing loader —
      no loader change needed). A `depends_on` on an unknown goal id, or a cycle
      among explicit edges, is a load error naming the offending file(s).
    * **inferred (overlap)** — between any two nodes whose declared `[scope]`
      paths overlap (one path prefix-contains the other, after normalization)
      when no explicit edge already orders them. Overlap = same blast radius =
      never concurrent, the same rule `Kazi.Enforcement.Isolation` applies WITHIN
      a goal-file, lifted to ACROSS goal-files. Ordered by file sequence (the
      earlier-loaded file is the edge's `from`), since neither node depends on
      the other semantically. A node with NO declared scope paths gets NO
      inferred edges — an empty scope is not treated as "overlaps everything"
      (that would serialize the whole fleet on the first unscoped goal).

  Scope comparison prefers `write_paths` over `paths` when a node declares
  `write_paths` (the sharper signal — see `Kazi.Scope` issue #860); falls back to
  `paths` otherwise.
  """

  alias Kazi.Goal
  alias Kazi.Goal.Loader
  alias Kazi.Scope

  defmodule Node do
    @moduledoc "One fleet member: a loaded goal, the file it came from."
    @type t :: %__MODULE__{id: String.t(), file: Path.t(), goal: Goal.t()}
    defstruct [:id, :file, :goal]
  end

  defmodule Edge do
    @moduledoc "One fleet edge: `from` must precede `to`."
    @type kind :: :explicit | :inferred_overlap
    @type t :: %__MODULE__{
            from: String.t(),
            to: String.t(),
            kind: kind(),
            overlap: [{String.t(), String.t()}]
          }
    defstruct [:from, :to, :kind, overlap: []]
  end

  @type t :: %__MODULE__{nodes: [Node.t()], edges: [Edge.t()]}
  defstruct nodes: [], edges: []

  @doc """
  Loads a fleet from a directory of `*.goal.toml` files or a manifest `.toml`
  file. Returns `{:error, reason}` — naming the offending file(s) — for an
  unloadable member, a dangling `depends_on`, an explicit-edge cycle, or a
  duplicate goal id.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) when is_binary(path) do
    with {:ok, files} <- member_files(path),
         {:ok, nodes} <- load_nodes(files),
         :ok <- validate_no_duplicate_ids(nodes),
         {:ok, explicit_edges} <- build_explicit_edges(nodes),
         :ok <- validate_no_cycle(nodes, explicit_edges) do
      inferred_edges = build_inferred_edges(nodes, explicit_edges)
      {:ok, %__MODULE__{nodes: nodes, edges: explicit_edges ++ inferred_edges}}
    end
  end

  @doc """
  The topological frontiers over the fleet's edges: a list of waves, each wave a
  list of node ids whose every predecessor (by `edges`) is in an earlier wave.
  Pure — `load/1` already rejected cycles, so this always terminates covering
  every node exactly once.
  """
  @spec frontiers(t()) :: [[String.t()]]
  def frontiers(%__MODULE__{nodes: nodes, edges: edges}) do
    ids = Enum.map(nodes, & &1.id)

    deps_by_id =
      Map.new(ids, fn id ->
        {id, edges |> Enum.filter(&(&1.to == id)) |> Enum.map(& &1.from)}
      end)

    layer(ids, deps_by_id, MapSet.new(), [])
  end

  defp layer([], _deps_by_id, _done, acc), do: Enum.reverse(acc)

  defp layer(remaining, deps_by_id, done, acc) do
    {ready, rest} =
      Enum.split_with(remaining, fn id ->
        deps_by_id |> Map.get(id, []) |> Enum.all?(&MapSet.member?(done, &1))
      end)

    if ready == [] do
      # Unreachable when `load/1`'s cycle guard has run first, but total rather
      # than looping forever on a caller-built %__MODULE__{} with a manual cycle.
      Enum.reverse(acc)
    else
      done = Enum.reduce(ready, done, &MapSet.put(&2, &1))
      layer(rest, deps_by_id, done, [ready | acc])
    end
  end

  # --- member discovery ---

  defp member_files(path) do
    cond do
      File.dir?(path) ->
        files =
          path
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".goal.toml"))
          |> Enum.sort()
          |> Enum.map(&Path.join(path, &1))

        if files == [] do
          {:error, "fleet directory #{path} contains no *.goal.toml files"}
        else
          {:ok, files}
        end

      File.regular?(path) ->
        load_manifest(path)

      true ->
        {:error, "fleet path #{path} does not exist"}
    end
  end

  defp load_manifest(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, data} <- Toml.decode(contents) do
      base = Path.dirname(path)

      files =
        data
        |> Map.get("member", [])
        |> Enum.map(&Map.get(&1, "path"))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&resolve_member_path(&1, base))

      if files == [] do
        {:error, "fleet manifest #{path} declares no [[member]] path entries"}
      else
        {:ok, files}
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, "fleet manifest #{path}: #{reason}"}
      {:error, reason} -> {:error, "fleet manifest #{path}: malformed TOML: #{inspect(reason)}"}
    end
  end

  defp resolve_member_path(rel, base) do
    if Path.type(rel) == :absolute, do: rel, else: Path.join(base, rel)
  end

  # --- node loading ---

  defp load_nodes(files) do
    files
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case Loader.load(file) do
        {:ok, goal} -> {:cont, {:ok, [%Node{id: goal.id, file: file, goal: goal} | acc]}}
        {:error, reason} -> {:halt, {:error, "could not load fleet member #{file}: #{reason}"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # --- duplicate goal ids ---

  defp validate_no_duplicate_ids(nodes) do
    nodes
    |> Enum.group_by(& &1.id)
    |> Enum.find(fn {_id, group} -> length(group) > 1 end)
    |> case do
      nil ->
        :ok

      {id, group} ->
        files = group |> Enum.map(& &1.file) |> Enum.join(", ")
        {:error, "duplicate goal id #{inspect(id)} declared in multiple fleet members: #{files}"}
    end
  end

  # --- explicit `[metadata] depends_on` edges ---

  defp build_explicit_edges(nodes) do
    declared = MapSet.new(nodes, & &1.id)

    nodes
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      case depends_on(node) do
        {:ok, deps} ->
          case Enum.find(deps, &(not MapSet.member?(declared, &1))) do
            nil ->
              edges = Enum.map(deps, fn dep -> %Edge{from: dep, to: node.id, kind: :explicit} end)
              {:cont, {:ok, edges ++ acc}}

            unknown ->
              {:halt,
               {:error,
                "goal #{inspect(node.id)} (#{node.file}) depends_on unknown goal id " <>
                  "#{inspect(unknown)} (declared: #{declared_ids(declared)})"}}
          end

        {:error, reason} ->
          {:halt, {:error, "goal #{inspect(node.id)} (#{node.file}): #{reason}"}}
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

  defp depends_on(%Node{goal: %Goal{metadata: metadata}}) do
    case Map.get(metadata, "depends_on") do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, "[metadata] depends_on must be a list of goal-id strings"}
        end

      _other ->
        {:error, "[metadata] depends_on must be a list of goal-id strings"}
    end
  end

  # --- explicit-edge cycle detection ---
  #
  # DFS with a `finished` memo (mirrors `Kazi.Goal.Loader.validate_no_needs_cycle/1`)
  # so a diamond of explicit edges is not re-walked once per path to a shared
  # descendant.

  defp validate_no_cycle(nodes, edges) do
    deps_by_id =
      Map.new(nodes, fn node ->
        deps = edges |> Enum.filter(&(&1.to == node.id)) |> Enum.map(& &1.from)
        {node.id, deps}
      end)

    {result, _finished} =
      Enum.reduce_while(nodes, {:ok, MapSet.new()}, fn node, {:ok, finished} ->
        case walk(node.id, deps_by_id, MapSet.new(), finished) do
          {:ok, finished} -> {:cont, {:ok, finished}}
          {:cycle, a, b} -> {:halt, {{:error, cycle_message(a, b, nodes)}, finished}}
        end
      end)

    result
  end

  defp cycle_message(a, b, nodes) do
    "fleet dependency cycle between #{inspect(a)} (#{file_for(nodes, a)}) and " <>
      "#{inspect(b)} (#{file_for(nodes, b)})"
  end

  defp file_for(nodes, id) do
    case Enum.find(nodes, &(&1.id == id)) do
      %Node{file: file} -> file
      nil -> "?"
    end
  end

  defp walk(id, deps_by_id, stack, finished) do
    cond do
      MapSet.member?(finished, id) ->
        {:ok, finished}

      MapSet.member?(stack, id) ->
        {:cycle, id, id}

      true ->
        stack = MapSet.put(stack, id)

        deps_by_id
        |> Map.get(id, [])
        |> Enum.reduce_while({:ok, finished}, fn dep, {:ok, finished} ->
          if MapSet.member?(stack, dep) do
            {:halt, {:cycle, id, dep}}
          else
            case walk(dep, deps_by_id, stack, finished) do
              {:ok, finished} -> {:cont, {:ok, finished}}
              {:cycle, _, _} = cycle -> {:halt, cycle}
            end
          end
        end)
        |> case do
          {:ok, finished} -> {:ok, MapSet.put(finished, id)}
          {:cycle, _, _} = cycle -> cycle
        end
    end
  end

  # --- inferred scope-overlap edges ---

  defp build_inferred_edges(nodes, explicit_edges) do
    indexed = Enum.with_index(nodes)
    ordered_pairs = for {a, i} <- indexed, {b, j} <- indexed, i < j, do: {a, b}

    explicit_pairs =
      explicit_edges
      |> Enum.flat_map(fn e -> [{e.from, e.to}, {e.to, e.from}] end)
      |> MapSet.new()

    Enum.flat_map(ordered_pairs, fn {a, b} ->
      if MapSet.member?(explicit_pairs, {a.id, b.id}) do
        []
      else
        case overlapping_paths(a, b) do
          [] -> []
          overlap -> [%Edge{from: a.id, to: b.id, kind: :inferred_overlap, overlap: overlap}]
        end
      end
    end)
  end

  defp overlapping_paths(%Node{goal: goal_a}, %Node{goal: goal_b}) do
    paths_a = scope_paths(goal_a)
    paths_b = scope_paths(goal_b)

    if paths_a == [] or paths_b == [] do
      []
    else
      for p1 <- paths_a, p2 <- paths_b, paths_overlap?(p1, p2), do: {p1, p2}
    end
  end

  # Prefer `write_paths` (the sharper signal) when a node declares any; fall
  # back to the coarser `paths` read allow-list otherwise (issue #860).
  defp scope_paths(%Goal{scope: %Scope{write_paths: []} = scope}), do: scope.paths
  defp scope_paths(%Goal{scope: %Scope{write_paths: write_paths}}), do: write_paths

  defp paths_overlap?(a, b) do
    na = normalize_path(a)
    nb = normalize_path(b)
    String.starts_with?(na, nb) or String.starts_with?(nb, na)
  end

  defp normalize_path(path), do: String.trim_trailing(path, "/") <> "/"
end

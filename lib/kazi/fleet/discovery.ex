defmodule Kazi.Fleet.Discovery do
  @moduledoc """
  Discovers a **fleet** — a directory of `*.goal.toml` goal-files driven as one
  unit (T50.4, ADR-0065) — and computes its goal-DAG.

  An edge between two fleet members comes from EITHER:

    * an explicit `[metadata] depends_on = ["other-goal-id"]` array in a
      goal-file (`:explicit`), or
    * an INFERRED overlap between the two goal-files' `[scope] paths` glob
      patterns, when neither declares an explicit edge to the other
      (`:inferred_overlap`) — two goals whose scope could touch the same file
      must never run concurrently, so they are serialized (not errored).

  A pair with neither an explicit edge nor an overlapping scope is
  INDEPENDENT — no edge, free to run in the same frontier.

  Loading is load-time validated (T50.4): a `depends_on` entry naming a
  goal-id absent from the directory, or a dependency cycle (explicit and/or
  inferred), is a hard `{:error, message}` naming the OFFENDING FILE PATHS —
  a caller debugging a fleet needs to find the file, not just the goal-id.

  This module only DISCOVERS and SCHEDULES (computes frontiers); it never
  loads a harness, worktree, or lease — that is fleet EXECUTION (T50.5).
  """

  alias Kazi.Goal
  alias Kazi.Goal.Loader

  @typedoc "How an edge between two fleet members was derived."
  @type edge_kind :: :explicit | :inferred_overlap

  @typedoc "One fleet member: its loaded goal plus the file it came from."
  @type member :: %{goal: Goal.t(), file: Path.t()}

  @typedoc """
  One DAG edge: `from` must converge before `to` is ready. For an
  `:inferred_overlap` edge the direction is a DETERMINISTIC tie-break (the
  lexicographically smaller goal id runs first) — the pair has no authored
  ordering preference, only a "never concurrently" constraint, so any total
  order that keeps them apart is honest.
  """
  @type edge :: %{from: Goal.id(), to: Goal.id(), kind: edge_kind()}

  @typedoc """
  A discovered fleet: its members (in loaded/declared file order), the
  computed edges, and the topological FRONTIERS (`Kazi.Goal.DepGraph.frontiers/1`'s
  shape, one level up — over goal-files instead of predicate groups).
  """
  @type t :: %__MODULE__{
          members: [member()],
          edges: [edge()],
          frontiers: [[Goal.id()]]
        }

  @enforce_keys [:members, :edges, :frontiers]
  defstruct members: [], edges: [], frontiers: []

  @doc """
  Loads every `*.goal.toml` file directly under `dir`, builds the goal-DAG, and
  returns the discovered fleet with its computed frontiers — or a load error
  naming the offending file path(s).
  """
  @spec discover(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def discover(dir) when is_binary(dir) do
    with {:ok, files} <- list_goal_files(dir),
         {:ok, members} <- load_members(files),
         :ok <- validate_dependencies(members) do
      edges = explicit_edges(members) ++ inferred_edges(members)

      case layer(members, edges) do
        {:ok, frontiers} ->
          {:ok, %__MODULE__{members: members, edges: edges, frontiers: frontiers}}

        {:error, stuck_ids} ->
          {:error, cycle_error(members, stuck_ids)}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # loading
  # ---------------------------------------------------------------------------

  defp list_goal_files(dir) do
    if File.dir?(dir) do
      case dir |> Path.join("*.goal.toml") |> Path.wildcard() |> Enum.sort() do
        [] -> {:error, "no *.goal.toml files found in #{dir}"}
        files -> {:ok, files}
      end
    else
      {:error, "#{dir} is not a directory"}
    end
  end

  defp load_members(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case Loader.load(file) do
        {:ok, goal} -> {:cont, {:ok, [%{goal: goal, file: file} | acc]}}
        {:error, reason} -> {:halt, {:error, "could not load #{file}: #{reason}"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # A `depends_on` entry naming a goal-id absent from the loaded set is a hard
  # load error naming the OFFENDING FILE (the one that declared it).
  defp validate_dependencies(members) do
    known = Enum.map(members, & &1.goal.id)

    Enum.reduce_while(members, :ok, fn %{goal: goal, file: file}, :ok ->
      case depends_on(goal) -- known do
        [] ->
          {:cont, :ok}

        [missing | _] ->
          {:halt,
           {:error,
            "#{file} declares depends_on #{inspect(missing)}, which does not match any goal id loaded from this fleet"}}
      end
    end)
  end

  defp depends_on(%Goal{metadata: metadata}) do
    case Map.get(metadata, "depends_on") do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # edges
  # ---------------------------------------------------------------------------

  defp explicit_edges(members) do
    for %{goal: goal} <- members,
        dep <- depends_on(goal),
        do: %{from: dep, to: goal.id, kind: :explicit}
  end

  defp inferred_edges(members) do
    explicit_pairs =
      members
      |> Enum.flat_map(fn %{goal: goal} ->
        Enum.map(depends_on(goal), &MapSet.new([&1, goal.id]))
      end)
      |> MapSet.new()

    for {a, b} <- unordered_pairs(members),
        not MapSet.member?(explicit_pairs, MapSet.new([a.goal.id, b.goal.id])),
        scopes_overlap?(a.goal.scope.paths, b.goal.scope.paths) do
      [first, second] = Enum.sort([a.goal.id, b.goal.id])
      %{from: first, to: second, kind: :inferred_overlap}
    end
  end

  defp unordered_pairs(members) do
    indexed = Enum.with_index(members)

    for {a, i} <- indexed, {b, j} <- indexed, i < j, do: {a, b}
  end

  defp scopes_overlap?(paths_a, paths_b) do
    Enum.any?(paths_a, fn pa -> Enum.any?(paths_b, &pattern_overlap?(pa, &1)) end)
  end

  # Two glob patterns overlap iff one's static (non-wildcard) directory prefix
  # is an ancestor of (or equal to) the other's — the coarsest honest signal
  # that some file could match both (mirrors the "paths not symbols" call
  # `Kazi.Partition` already makes for blast-radius overlap, one level up).
  defp pattern_overlap?(a, b) do
    pa = static_prefix(a)
    pb = static_prefix(b)
    ancestor_or_equal?(pa, pb) or ancestor_or_equal?(pb, pa)
  end

  defp ancestor_or_equal?(prefix, segments) do
    Enum.take(segments, length(prefix)) == prefix
  end

  defp static_prefix(pattern) do
    case wildcard_index(pattern) do
      nil -> Path.split(pattern)
      idx -> pattern |> String.slice(0, idx) |> Path.split()
    end
  end

  defp wildcard_index(pattern) do
    pattern
    |> String.to_charlist()
    |> Enum.find_index(&(&1 in ~c"*?[{"))
  end

  # ---------------------------------------------------------------------------
  # topological frontiers (mirrors `Kazi.Goal.DepGraph.frontiers/1`, one level
  # up over goal-files instead of predicate groups)
  # ---------------------------------------------------------------------------

  defp layer(members, edges) do
    ids = Enum.map(members, & &1.goal.id)
    needs = needs_map(members, edges)
    frontiers = layer_frontiers(ids, needs, MapSet.new(), [])

    case ids -- List.flatten(frontiers) do
      [] -> {:ok, frontiers}
      stuck -> {:error, stuck}
    end
  end

  defp needs_map(members, edges) do
    base = Map.new(members, fn %{goal: goal} -> {goal.id, MapSet.new()} end)

    Enum.reduce(edges, base, fn %{from: dep, to: dependent}, acc ->
      Map.update(acc, dependent, MapSet.new([dep]), &MapSet.put(&1, dep))
    end)
  end

  defp layer_frontiers(ids, needs, converged, acc) do
    ready =
      Enum.filter(ids, fn id ->
        not MapSet.member?(converged, id) and
          needs |> Map.get(id, MapSet.new()) |> Enum.all?(&MapSet.member?(converged, &1))
      end)

    case ready do
      [] ->
        Enum.reverse(acc)

      ready ->
        converged = Enum.reduce(ready, converged, &MapSet.put(&2, &1))
        layer_frontiers(ids, needs, converged, [ready | acc])
    end
  end

  defp cycle_error(members, stuck_ids) do
    files =
      members
      |> Enum.filter(fn %{goal: goal} -> goal.id in stuck_ids end)
      |> Enum.map(& &1.file)

    "dependency cycle detected among goal-files: #{Enum.join(files, ", ")}"
  end
end

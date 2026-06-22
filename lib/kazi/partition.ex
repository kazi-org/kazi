defmodule Kazi.Partition do
  @moduledoc """
  Disjoint **blast-radius partitions** of a set of goals (T3.2a, ADR-0006; UC-014).

  kazi coordinates parallel work on **resources, not identities** (ADR-0006):
  two goals may run concurrently iff the code they would touch — their *blast
  radii* — do not overlap; goals whose blast radii intersect must serialize on a
  shared lease (T3.1) instead of colliding. This module computes that grouping.

  Given a set of goals, each named with the terms it starts from (its changed
  files / target symbols), `partition/2`:

    1. expands each goal's blast radius through the injectable
       `Kazi.Context.GraphSource` seam (T4.2) — the same code-review-graph
       impact-radius lookup `Kazi.Context` uses, so there is **no new graph
       client** and tests inject `Kazi.Context.StaticGraphSource` for a hermetic,
       network-free run;
    2. groups goals whose blast radii **overlap** into one partition by transitive
       closure (union-find): A∩B and B∩C put A, B, C in the same partition even
       when A∩C is empty;
    3. returns goals with disjoint radii as **separate** partitions.

  Each `Kazi.Partition` carries the member goal ids, the union of their
  blast-radius paths, and a stable `key` — a hash of that sorted radius — that
  **T3.2b maps directly to a `Kazi.Coordination.Lease` key** (`t:Kazi.Coordination.Lease.key/0`
  is a `String.t/0`). Overlapping goals land in one partition, so they derive one
  key and serialize on one lease; disjoint partitions derive distinct keys and
  proceed in parallel.

  ## Blast radius

  A goal's blast radius is the **set of workspace-relative file paths** the graph
  source surfaces for its terms: the impacted `files`, the files defining the
  impacted `symbols`, and the failing `test_sources`. Two goals overlap iff these
  path sets intersect. Paths (not symbols) are the unit because the lease and the
  scope (`Kazi.Scope.paths`) are path-shaped, and a shared file is the coarsest
  honest signal that two edits can conflict.

  ## Determinism (a hard requirement)

  T3.2b derives lease keys from these partitions, so the partitioning must be a
  pure function of its inputs: same goals + same source ⇒ identical partitions,
  identical keys, identical order, across repeated calls. So this module:

    * stores every blast radius as a **sorted, de-duplicated** list of paths,
    * orders a partition's `goal_ids` by the goal id's string form,
    * orders the returned partitions by their sorted `goal_ids`,
    * derives `key` as `sha256` of the newline-joined sorted radius (no map
      ordering, no timestamps, no randomness).

  A goal whose blast radius is empty (the source found nothing) still becomes its
  own singleton partition — it shares paths with no one — keyed off its goal id so
  the key is stable and distinct.
  """

  alias Kazi.Context.RepoMapSource

  @typedoc """
  A goal to partition: its stable id plus the evidence terms (changed-file paths /
  target symbol names) its blast radius is expanded from. Accepts either:

    * a `{goal_id, evidence_terms}` tuple, or
    * a `Kazi.Goal` struct (its `id`; terms default to `[]` unless supplied), or
    * a `%{id: ..., terms: [...]}` map.
  """
  @type goal_input ::
          {Kazi.Goal.id(), [String.t()]}
          | Kazi.Goal.t()
          | %{required(:id) => Kazi.Goal.id(), optional(:terms) => [String.t()]}

  @typedoc """
    * `:goal_ids` — the member goals, sorted by their string form.
    * `:blast_radius` — the sorted, de-duplicated union of the members'
      blast-radius file paths.
    * `:key` — a stable `sha256` hex of the blast radius (singleton goals with an
      empty radius key off their goal id). **T3.2b uses this as the lease key.**
  """
  @type t :: %__MODULE__{
          goal_ids: [Kazi.Goal.id()],
          blast_radius: [String.t()],
          key: String.t()
        }

  @enforce_keys [:goal_ids, :blast_radius, :key]
  defstruct goal_ids: [], blast_radius: [], key: nil

  @typedoc """
  Options:

    * `:graph_source` — a module implementing `Kazi.Context.GraphSource`, or a
      `{module, init_opts}` tuple. Injected for hermetic tests (pass
      `Kazi.Context.StaticGraphSource`). Defaults to `Kazi.Context.RepoMapSource`,
      the same default `Kazi.Context` uses.
  """
  @type opts :: [graph_source: module() | {module(), keyword()}]

  @doc """
  Partitions `goals` into disjoint blast-radius groups against `workspace`.

  Expands each goal's blast radius through the injected `Kazi.Context.GraphSource`
  (one `survey/3` call per goal), then groups goals whose radii overlap by
  transitive closure and returns the groups as `Kazi.Partition` structs, ordered
  deterministically.

  Pure and hermetic with an injected source: same inputs ⇒ identical partitions
  (and identical `key`s) across calls, no network or live-MCP access.

  ## Examples

      iex> overlap = Kazi.Context.StaticGraphSource.new(files: ["lib/a.ex"])
      iex> goals = [{"g1", ["a"]}, {"g2", ["a"]}]
      iex> parts = Kazi.Partition.partition(goals, "/ws", graph_source: overlap)
      iex> length(parts)
      1
      iex> hd(parts).goal_ids
      ["g1", "g2"]
  """
  @spec partition([goal_input()], String.t(), opts()) :: [t()]
  def partition(goals, workspace, opts \\ [])
      when is_list(goals) and is_binary(workspace) and is_list(opts) do
    {source_mod, source_opts} =
      resolve_source(Keyword.get(opts, :graph_source, RepoMapSource))

    # One survey per goal -> {goal_id, sorted unique blast-radius paths}. Sorted
    # on the goal id's string form first so equal-key tie-breaks are stable.
    radii =
      goals
      |> Enum.map(&normalize_goal/1)
      |> Enum.map(fn {id, terms} ->
        survey = source_mod.survey(workspace, terms, source_opts)
        {id, blast_radius(survey)}
      end)
      |> Enum.sort_by(fn {id, _radius} -> to_string(id) end)

    radii
    |> group_overlapping()
    |> Enum.map(&build_partition/1)
    |> Enum.sort_by(fn %__MODULE__{goal_ids: ids} -> Enum.map(ids, &to_string/1) end)
  end

  # --- blast radius -----------------------------------------------------------

  # The set of file paths a survey touches: impacted files, the files defining the
  # impacted symbols, and the failing test sources. Sorted + de-duplicated so the
  # radius (and any key derived from it) is byte-stable.
  defp blast_radius(survey) do
    [
      Enum.map(survey.files, & &1.path),
      Enum.map(survey.symbols, & &1.path),
      Enum.map(survey.test_sources, & &1.path)
    ]
    |> Enum.concat()
    |> Enum.uniq()
    |> Enum.sort()
  end

  # --- transitive-closure grouping (union-find by shared path) ----------------

  # Groups `{id, radius}` entries into clusters whose radii transitively overlap.
  # Walks the entries in their (already stable) order, merging each into the first
  # existing cluster it shares a path with, then collapsing clusters that a later
  # entry bridges. Returns a list of clusters, each a list of `{id, radius}`.
  defp group_overlapping(radii) do
    Enum.reduce(radii, [], fn entry, clusters ->
      {touched, untouched} = Enum.split_with(clusters, &overlaps_cluster?(&1, entry))

      # `entry` bridges every cluster in `touched` (transitive closure): fold them
      # and `entry` into one cluster, keeping the clusters it did not touch.
      merged = [entry | Enum.concat(touched)]
      [merged | untouched]
    end)
  end

  defp overlaps_cluster?(cluster, {_id, radius}) do
    radius_set = MapSet.new(radius)

    Enum.any?(cluster, fn {_other_id, other_radius} ->
      sets_intersect?(radius_set, other_radius)
    end)
  end

  # A pair sharing *no* paths (both empty included) never overlaps, so empty-radius
  # goals stay singletons.
  defp sets_intersect?(_set, []), do: false
  defp sets_intersect?(set, other_radius), do: Enum.any?(other_radius, &MapSet.member?(set, &1))

  # --- partition assembly -----------------------------------------------------

  defp build_partition(cluster) do
    goal_ids = cluster |> Enum.map(fn {id, _radius} -> id end) |> Enum.sort_by(&to_string/1)

    blast_radius =
      cluster
      |> Enum.flat_map(fn {_id, radius} -> radius end)
      |> Enum.uniq()
      |> Enum.sort()

    %__MODULE__{
      goal_ids: goal_ids,
      blast_radius: blast_radius,
      key: partition_key(goal_ids, blast_radius)
    }
  end

  @doc """
  The stable lease key for a partition — a `sha256` hex of its sorted blast radius
  (T3.2b maps this 1:1 to a `Kazi.Coordination.Lease` key).

  Overlapping goals share one partition, hence one radius, hence one key (they
  serialize on one lease); disjoint partitions hash distinct radii to distinct
  keys (they run in parallel). A partition whose radius is empty keys off its
  sorted `goal_ids` instead, so a no-blast-radius singleton still has a stable,
  distinct key rather than colliding with every other empty radius.

  Exposed (not just internal) so T3.2b can derive a lease key from a partition's
  members + radius without reaching into the struct's hashing.

  ## Examples

      iex> k = Kazi.Partition.partition_key(["g1"], ["lib/a.ex"])
      iex> k == Kazi.Partition.partition_key(["g1"], ["lib/a.ex"])
      true
      iex> k != Kazi.Partition.partition_key(["g1"], ["lib/b.ex"])
      true
  """
  @spec partition_key([Kazi.Goal.id()], [String.t()]) :: String.t()
  def partition_key(goal_ids, blast_radius)
      when is_list(goal_ids) and is_list(blast_radius) do
    payload =
      case Enum.sort(blast_radius) do
        [] -> "goals:" <> (goal_ids |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(","))
        radius -> "radius:" <> Enum.join(radius, "\n")
      end

    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  # --- input normalization ----------------------------------------------------

  defp normalize_goal({id, terms}) when is_list(terms), do: {id, terms}
  defp normalize_goal(%Kazi.Goal{id: id} = goal), do: {id, goal_terms(goal)}

  defp normalize_goal(%{id: id} = map) when is_map(map),
    do: {id, Map.get(map, :terms, [])}

  # A bare `Kazi.Goal` carries no explicit partition terms; future wiring (T3.2b)
  # may seed them from the goal's scope/changed-set, but here an unsupplied goal
  # contributes only its id (an empty radius -> its own singleton partition).
  defp goal_terms(%Kazi.Goal{metadata: %{partition_terms: terms}}) when is_list(terms), do: terms
  defp goal_terms(%Kazi.Goal{}), do: []

  # Mirrors Kazi.Context.resolve_source: accept a bare module or a {module, opts}
  # tuple so a test double can carry its fixture via init opts.
  defp resolve_source({module, source_opts}) when is_atom(module) and is_list(source_opts),
    do: {module, source_opts}

  defp resolve_source(module) when is_atom(module), do: {module, []}
end

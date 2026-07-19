defmodule Kazi.Goal.GroupTree do
  @moduledoc """
  Reconstructs a goal's declared group taxonomy into a TREE and rolls up
  predicate verdicts per group (T12.3, ADR-0020 §Decision 1–4).

  A `Kazi.Goal` declares its taxonomy FLAT — a list of `Kazi.Goal.Group`s, each
  carrying an optional `parent` id — so a 300-node hierarchy is authorable and
  diffable without literal nesting (ADR-0020 §Alternatives rejected). This module
  is the pure counterpart: it walks the `parent` links to reconstruct the tree to
  arbitrary depth (pillar → domain → capability), and rolls each group's
  predicate verdicts — its OWN predicates plus every descendant group's,
  recursively — into intended / built / pending counts so the operator can read
  "where is the goal: what is intended, built, pending" per pillar (ADR-0020
  §Context).

  ## Verdict semantics

  A predicate's verdict is taken from a caller-supplied map of predicate id →
  passing?. This module is PURE — it does NOT evaluate predicates; it only reads
  the verdicts the caller already holds (e.g. a `Kazi.PredicateVector`'s
  pass/fail per id). A predicate with no entry in the verdict map is treated as
  not yet passing (pending), so a freshly-authored goal with no observation yet
  rolls up as all-pending — the desired "intended, nothing built" reading.

  Per ADR-0020 §Decision 5 (the exporter tags nodes intended / built / pending):

    * `intended` — every predicate in the group's scope (its own + descendants').
      The declared intent: the total the group commits to.
    * `built` — predicates in scope whose verdict is passing.
    * `pending` — predicates in scope not yet passing (`intended - built`); the
      work remaining. An acceptance predicate authored to fail at t0 (T2.1) reads
      as pending until kazi builds it.

  So `intended == built + pending` always holds, per group.

  ## Tree shape

  `tree/1` returns a list of ROOT nodes (groups with no parent, or whose parent
  is not declared — a dangling parent is treated as a root rather than dropped,
  so no group is silently lost). Each node is:

      %{group: %Kazi.Goal.Group{}, children: [node()]}

  Children preserve the goal's declared group order at every level, so the tree
  is deterministic: the same goal yields the same tree.

  ## Pure + deterministic

  Every function here is a pure function of its inputs (a `Kazi.Goal` and a
  verdict map) — no I/O, no process state, no evaluation. The same goal and the
  same verdicts always yield the same tree and the same rollup.

  ## Backward compatibility

  A goal with no declared groups yields an empty tree (`tree/1 == []`) and an
  empty rollup (`rollup/2 == %{}`); the ungrouped predicates are simply not
  attributed to any group, exactly as before the taxonomy existed.
  """

  alias Kazi.Goal
  alias Kazi.Goal.Group
  alias Kazi.Predicate

  @typedoc """
  A verdict map: predicate id → whether that predicate is currently passing.
  An id absent from the map is treated as not-passing (pending). Built by the
  caller from whatever verdict shape it holds (e.g. a `Kazi.PredicateVector`);
  see `verdicts_from_vector/1` for the `PredicateVector` adapter.
  """
  @type verdicts :: %{optional(Predicate.id()) => boolean()}

  @typedoc "A node in the reconstructed group tree."
  @type node_t :: %{group: Group.t(), children: [node_t()]}

  @typedoc """
  A per-group status rollup. `intended == built + pending`; counts include the
  group's OWN predicates plus all descendant groups', recursively.
  """
  @type counts :: %{
          intended: non_neg_integer(),
          built: non_neg_integer(),
          pending: non_neg_integer()
        }

  @doc """
  Reconstructs the goal's group taxonomy into a tree of nodes.

  Returns the ROOT nodes (groups with no `parent`, or whose `parent` is not a
  declared id). Each node is `%{group: Group.t(), children: [node]}`, nested to
  arbitrary depth by following the `parent` links. Sibling order at every level
  preserves the goal's declared group order, so the result is deterministic.

  A goal with no groups yields `[]`.

  ## Examples

      iex> pillar = Kazi.Goal.Group.new("identity", "Identity")
      iex> domain = Kazi.Goal.Group.new("sign-up", "Sign Up", parent: "identity")
      iex> g = Kazi.Goal.new("g", groups: [pillar, domain])
      iex> [root] = Kazi.Goal.GroupTree.tree(g)
      iex> {root.group.id, length(root.children)}
      {"identity", 1}
      iex> [child] = root.children
      iex> child.group.id
      "sign-up"

      iex> Kazi.Goal.GroupTree.tree(Kazi.Goal.new("g"))
      []
  """
  @spec tree(Goal.t()) :: [node_t()]
  def tree(%Goal{groups: groups}) do
    declared = MapSet.new(groups, & &1.id)
    children_by_parent = Enum.group_by(groups, & &1.parent)

    groups
    |> Enum.filter(&root?(&1, declared))
    |> Enum.map(&build_node(&1, children_by_parent))
  end

  @doc """
  Rolls up predicate verdicts into per-group `intended / built / pending` counts.

  Returns a map of group id → `%{intended:, built:, pending:}`. Each group's
  counts include its OWN predicates (those whose `group` is this group's id)
  PLUS every descendant group's predicates, recursively (ADR-0020 §Decision 1 —
  a parent rolls up its descendants). `intended == built + pending` per group.

  `verdicts` is a map of predicate id → passing?; an id absent from the map is
  counted as not-passing (pending). This function does NOT evaluate predicates —
  it reads only the verdicts the caller supplies, so it is pure and
  deterministic.

  A goal with no groups yields `%{}`.

  ## Examples

      iex> pillar = Kazi.Goal.Group.new("identity", "Identity")
      iex> domain = Kazi.Goal.Group.new("sign-up", "Sign Up", parent: "identity")
      iex> g = Kazi.Goal.new("g",
      ...>   groups: [pillar, domain],
      ...>   predicates: [
      ...>     Kazi.Predicate.new(:p1, :tests, group: "identity"),
      ...>     Kazi.Predicate.new(:p2, :tests, group: "sign-up"),
      ...>     Kazi.Predicate.new(:p3, :tests, group: "sign-up")
      ...>   ])
      iex> roll = Kazi.Goal.GroupTree.rollup(g, %{p1: true, p2: true, p3: false})
      iex> roll["sign-up"]
      %{intended: 2, built: 1, pending: 1}
      iex> roll["identity"]
      %{intended: 3, built: 2, pending: 1}

      iex> Kazi.Goal.GroupTree.rollup(Kazi.Goal.new("g"), %{})
      %{}
  """
  @spec rollup(Goal.t(), verdicts()) :: %{optional(Group.id()) => counts()}
  def rollup(%Goal{groups: groups} = goal, verdicts \\ %{}) when is_map(verdicts) do
    own = own_counts(goal, verdicts)
    children_by_parent = Enum.group_by(groups, & &1.parent)
    declared = MapSet.new(groups, & &1.id)

    groups
    |> Enum.filter(&root?(&1, declared))
    |> Enum.reduce(%{}, fn root, acc ->
      accumulate(root, children_by_parent, own, acc)
    end)
  end

  @doc """
  Adapts a `Kazi.PredicateVector` into the `verdicts` map `rollup/2` expects:
  predicate id → whether its result is `:pass`.

  A convenience for the common caller that already holds a vector; `rollup/2`
  itself takes the plain map so it stays decoupled from the vector shape.

  ## Examples

      iex> v = Kazi.PredicateVector.new(%{
      ...>   p1: Kazi.PredicateResult.pass(),
      ...>   p2: Kazi.PredicateResult.fail()
      ...> })
      iex> Kazi.Goal.GroupTree.verdicts_from_vector(v)
      %{p1: true, p2: false}
  """
  @spec verdicts_from_vector(Kazi.PredicateVector.t()) :: verdicts()
  def verdicts_from_vector(%Kazi.PredicateVector{results: results}) do
    Map.new(results, fn {id, result} -> {id, Kazi.PredicateResult.passed?(result)} end)
  end

  # --- internals ---

  # A group roots the tree when it declares no parent, or when its declared
  # parent is not itself a declared group (a dangling parent surfaces as a root
  # rather than silently dropping the subtree).
  defp root?(%Group{parent: nil}, _declared), do: true
  defp root?(%Group{parent: parent}, declared), do: not MapSet.member?(declared, parent)

  defp build_node(%Group{} = group, children_by_parent) do
    children =
      children_by_parent
      |> Map.get(group.id, [])
      |> Enum.map(&build_node(&1, children_by_parent))

    %{group: group, children: children}
  end

  # The counts for each group's OWN predicates only (no descendants yet).
  defp own_counts(%Goal{groups: groups} = goal, verdicts) do
    by_group =
      goal
      |> Goal.all_predicates()
      |> Enum.filter(& &1.group)
      |> Enum.group_by(& &1.group)

    Map.new(groups, fn %Group{id: id} ->
      preds = Map.get(by_group, id, [])
      built = Enum.count(preds, &built?(&1, verdicts))
      intended = length(preds)
      {id, %{intended: intended, built: built, pending: intended - built}}
    end)
  end

  # A predicate is "built" iff its verdict is passing; an absent verdict (never
  # observed) is treated as not-passing (pending).
  defp built?(%Predicate{id: id}, verdicts), do: Map.get(verdicts, id, false) == true

  # Folds a subtree's own counts up into each ancestor: writes the subtree-total
  # for `node`'s group into `acc`, having first accumulated all its children.
  defp accumulate(%Group{} = group, children_by_parent, own, acc) do
    child_groups = Map.get(children_by_parent, group.id, [])

    acc = Enum.reduce(child_groups, acc, &accumulate(&1, children_by_parent, own, &2))

    subtotal =
      child_groups
      |> Enum.map(&Map.fetch!(acc, &1.id))
      |> Enum.reduce(Map.fetch!(own, group.id), &add_counts/2)

    Map.put(acc, group.id, subtotal)
  end

  defp add_counts(a, b) do
    %{
      intended: a.intended + b.intended,
      built: a.built + b.built,
      pending: a.pending + b.pending
    }
  end
end

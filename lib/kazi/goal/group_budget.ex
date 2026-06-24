defmodule Kazi.Goal.GroupBudget do
  @moduledoc """
  Computes each group's **effective derived budget** from a goal's declared
  group taxonomy (T12.4, ADR-0020 §Decision 1 & 4).

  A group's budget is never a hand-maintained parent number. Budgets are
  declared only where the work lives — the LEAVES — and a parent's effective
  budget is DERIVED: the SUM of its descendants' effective budgets. An explicit
  `budget` on a NON-LEAF group is a CAP that can only TIGHTEN that rollup
  (`effective = min(cap, sum-of-descendants)`); a cap declared ABOVE the sum is a
  NO-OP (the sum wins, the operator's chosen default — ADR-0020 §Decision 1: "a
  parent budget is either absent (= the sum) or a deliberate cap"). So a parent
  total can never drift from its children, and a cap is the only lever that
  changes the rollup, always downward.

  This is the GOAL-side group-taxonomy budget. It is a DISTINCT layer from the
  SCHEDULER's per-partition budget split/rollup (`Kazi.Scheduler.Budget`, T21.7):
  that one splits ONE declared `Kazi.Budget` ceiling across partitions and sums
  spend back up; this one rolls a tree of declared `[[group]]` caps up into each
  group's effective ceiling. They share the "derive what you can, store only the
  irreducible" principle but operate on different inputs.

  ## Effective budget per group

    * a LEAF group's effective budget is its OWN declared `budget` (or `nil` when
      it declares none — an undeclared leaf is unbounded, contributing nothing to
      a parent's sum);
    * a NON-LEAF group's effective budget is the SUM of its children's EFFECTIVE
      budgets (so caps compose down the tree), then TIGHTENED by the group's own
      declared cap if any: `min(cap, sum)`. A cap below the sum tightens to the
      cap; a cap at or above the sum is a no-op (sum wins);
    * a NON-LEAF group whose whole subtree declares NO budget (every descendant
      leaf is `nil`) and which declares no cap of its own is itself `nil`
      (unbounded). When such an all-`nil` subtree sits under a deliberate cap, the
      cap stands alone — there is no sum to tighten against, so the cap IS the
      effective budget rather than being zeroed away.

  ## Pure + deterministic

  Every function here is a pure function of a `Kazi.Goal` (its declared groups
  only — predicates and verdicts are irrelevant to a budget rollup). No I/O, no
  process state. The same goal always yields the same effective-budget map. The
  taxonomy is reconstructed from the same flat `parent` links
  `Kazi.Goal.GroupTree` walks, with the same "dangling parent surfaces as a root"
  rule, so a group is never silently dropped.

  ## Backward compatibility

  A goal with no declared groups yields an empty map (`effective/1 == %{}`). A
  goal whose groups declare no budgets at all yields every group mapped to `nil`
  (all unbounded) — sensible and additive: nothing changes for a goal authored
  before per-group budgets existed.
  """

  alias Kazi.Goal
  alias Kazi.Goal.Group

  @typedoc """
  An effective per-group budget. `nil` = unbounded (the group declared no cap and
  no descendant declared a budget). A non-`nil` value is the derived ceiling: the
  sum of descendant budgets, tightened by any declared cap.
  """
  @type effective :: non_neg_integer() | nil

  @doc """
  Computes each group's effective derived budget.

  Returns a map of group id → effective budget (`t:effective/0`). Each value is
  the DERIVED rollup of ADR-0020 §Decision 1:

    * a leaf's effective budget is its own declared `budget` (or `nil`);
    * a parent's effective budget is the sum of its descendants' effective
      budgets, tightened by its own declared cap (`min(cap, sum)`); a cap above
      the sum is a no-op.

  A goal with no groups yields `%{}`. A goal whose groups declare no budgets
  yields every group mapped to `nil`.

  ## Examples

      iex> groups = [
      ...>   Kazi.Goal.Group.new("identity", "Identity"),
      ...>   Kazi.Goal.Group.new("register", "Register", parent: "identity", budget: 5),
      ...>   Kazi.Goal.Group.new("verify", "Verify", parent: "identity", budget: 3)
      ...> ]
      iex> g = Kazi.Goal.new("g", groups: groups)
      iex> eff = Kazi.Goal.GroupBudget.effective(g)
      iex> {eff["register"], eff["verify"], eff["identity"]}
      {5, 3, 8}

      iex> # a parent cap BELOW the sum (8) tightens to the cap
      iex> groups = [
      ...>   Kazi.Goal.Group.new("identity", "Identity", budget: 6),
      ...>   Kazi.Goal.Group.new("register", "Register", parent: "identity", budget: 5),
      ...>   Kazi.Goal.Group.new("verify", "Verify", parent: "identity", budget: 3)
      ...> ]
      iex> Kazi.Goal.GroupBudget.effective(Kazi.Goal.new("g", groups: groups))["identity"]
      6

      iex> # a parent cap ABOVE the sum (8) is a no-op (sum wins)
      iex> groups = [
      ...>   Kazi.Goal.Group.new("identity", "Identity", budget: 100),
      ...>   Kazi.Goal.Group.new("register", "Register", parent: "identity", budget: 5),
      ...>   Kazi.Goal.Group.new("verify", "Verify", parent: "identity", budget: 3)
      ...> ]
      iex> Kazi.Goal.GroupBudget.effective(Kazi.Goal.new("g", groups: groups))["identity"]
      8

      iex> Kazi.Goal.GroupBudget.effective(Kazi.Goal.new("g"))
      %{}
  """
  @spec effective(Goal.t()) :: %{optional(Group.id()) => effective()}
  def effective(%Goal{groups: groups}) do
    children_by_parent = Enum.group_by(groups, & &1.parent)
    declared = MapSet.new(groups, & &1.id)

    groups
    |> Enum.filter(&root?(&1, declared))
    |> Enum.reduce(%{}, fn root, acc ->
      accumulate(root, children_by_parent, acc)
    end)
  end

  # --- internals ---

  # A group roots the tree when it declares no parent, or when its declared
  # parent is not itself declared (a dangling parent surfaces as a root rather
  # than silently dropping the subtree). Mirrors `Kazi.Goal.GroupTree`.
  defp root?(%Group{parent: nil}, _declared), do: true
  defp root?(%Group{parent: parent}, declared), do: not MapSet.member?(declared, parent)

  # Folds a subtree's effective budget into `acc`, writing every group in the
  # subtree (children first, then the group itself). Returns the updated acc; the
  # group's own effective value is read back from acc by its parent.
  defp accumulate(%Group{} = group, children_by_parent, acc) do
    child_groups = Map.get(children_by_parent, group.id, [])

    acc = Enum.reduce(child_groups, acc, &accumulate(&1, children_by_parent, &2))

    eff = effective_for(group, child_groups, acc)
    Map.put(acc, group.id, eff)
  end

  # A leaf (no children): its effective budget is its own declared cap (or nil).
  defp effective_for(%Group{budget: budget}, [], _acc), do: budget

  # A non-leaf: sum the children's already-computed effective budgets, then
  # tighten by this group's declared cap. `nil` children contribute nothing; if
  # every descendant is nil the subtree sum is nil (no lower bound), and the
  # effective budget is the declared cap alone (or nil when none is declared).
  defp effective_for(%Group{budget: cap}, child_groups, acc) do
    sum =
      child_groups
      |> Enum.map(&Map.fetch!(acc, &1.id))
      |> sum_effective()

    tighten(cap, sum)
  end

  # Sum effective child budgets, skipping unbounded (nil) ones. Returns nil iff
  # EVERY child is nil (the whole subtree is unbounded — there is no sum to cap
  # against), otherwise the sum of the bounded children.
  defp sum_effective(values) do
    case Enum.reject(values, &is_nil/1) do
      [] -> nil
      bounded -> Enum.sum(bounded)
    end
  end

  # Combine a declared cap with the derived descendant sum:
  #   * no cap            -> the sum is the effective budget (absent cap = the sum);
  #   * cap, no sum (nil) -> the cap stands alone (an all-unbounded subtree under a
  #                          deliberate ceiling);
  #   * cap and sum       -> min(cap, sum): a cap below tightens, a cap at/above is
  #                          a no-op (sum wins).
  defp tighten(nil, sum), do: sum
  defp tighten(cap, nil), do: cap
  defp tighten(cap, sum), do: min(cap, sum)
end

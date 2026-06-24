defmodule Kazi.Goal.GroupBudgetTest do
  use ExUnit.Case, async: true
  doctest Kazi.Goal.GroupBudget

  alias Kazi.Goal
  alias Kazi.Goal.{Group, GroupBudget}

  # A 3-level pillar -> domain -> capability fixture, budgets declared only at
  # the leaves (capabilities) per ADR-0020 §Decision 1 ("declare budgets only
  # where the work lives").
  #
  #   identity (pillar)
  #     sign-up (domain)
  #       register (capability)  budget 5
  #       verify   (capability)  budget 3
  #   billing  (pillar, leaf)    budget 7
  defp three_level_groups(opts \\ []) do
    [
      Group.new("identity", "Identity", Keyword.get(opts, :identity, [])),
      Group.new("sign-up", "Sign Up", [parent: "identity"] ++ Keyword.get(opts, :sign_up, [])),
      Group.new("register", "Register", parent: "sign-up", budget: 5),
      Group.new("verify", "Verify Email", parent: "sign-up", budget: 3),
      Group.new("billing", "Billing", budget: 7)
    ]
  end

  defp goal(groups), do: Goal.new("acme", groups: groups)

  describe "effective/1 — derived rollup (no stored parent value)" do
    test "a parent's effective budget EQUALS the sum of its descendants' leaf budgets" do
      eff = GroupBudget.effective(goal(three_level_groups()))

      # leaves carry their own declared value
      assert eff["register"] == 5
      assert eff["verify"] == 3
      assert eff["billing"] == 7

      # sign-up has no declared budget -> pure sum of its two leaves
      assert eff["sign-up"] == 8

      # identity has no declared budget -> sum of the sign-up subtree (8)
      assert eff["identity"] == 8
    end

    test "the parent value is derived, never read from a stored parent number" do
      # Declare a deliberately WRONG (stale) parent number well above the sum;
      # because a cap above the sum is a no-op, the rollup ignores it and still
      # reports the true sum — proving the parent's stored number is not used as
      # the value.
      groups = three_level_groups(identity: [budget: 999], sign_up: [budget: 999])
      eff = GroupBudget.effective(goal(groups))

      assert eff["sign-up"] == 8
      assert eff["identity"] == 8
    end

    test "rolls up to arbitrary (3-level) depth" do
      # register(5) + verify(3) -> sign-up(8) -> identity(8); billing(7) separate.
      eff = GroupBudget.effective(goal(three_level_groups()))
      assert eff["identity"] == 8
      assert eff["billing"] == 7
    end
  end

  describe "effective/1 — a non-leaf cap can only TIGHTEN" do
    test "a declared parent cap BELOW the sum tightens to the cap" do
      # sum at identity is 8; a cap of 6 tightens it.
      groups = three_level_groups(identity: [budget: 6])
      eff = GroupBudget.effective(goal(groups))

      assert eff["identity"] == 6
      # children are untouched by the parent cap (only the parent value tightens)
      assert eff["register"] == 5
      assert eff["verify"] == 3
      assert eff["sign-up"] == 8
    end

    test "a declared parent cap ABOVE the sum is a NO-OP (sum wins)" do
      groups = three_level_groups(identity: [budget: 100])
      eff = GroupBudget.effective(goal(groups))

      assert eff["identity"] == 8
    end

    test "a declared parent cap EQUAL to the sum is a no-op (sum wins, same value)" do
      groups = three_level_groups(identity: [budget: 8])
      assert GroupBudget.effective(goal(groups))["identity"] == 8
    end

    test "an intermediate cap composes down the tree (caps tighten the rollup at each level)" do
      # sign-up capped at 4 (below its sum of 8); identity then sums the TIGHTENED
      # sign-up (4), not the raw 8.
      groups = three_level_groups(sign_up: [budget: 4])
      eff = GroupBudget.effective(goal(groups))

      assert eff["sign-up"] == 4
      assert eff["identity"] == 4
    end
  end

  describe "effective/1 — a leaf's budget is its own declared value" do
    test "a leaf with a declared budget reports that budget" do
      groups = [Group.new("solo", "Solo", budget: 42)]
      assert GroupBudget.effective(goal(groups)) == %{"solo" => 42}
    end

    test "a leaf with no declared budget is nil (unbounded)" do
      groups = [Group.new("solo", "Solo")]
      assert GroupBudget.effective(goal(groups)) == %{"solo" => nil}
    end
  end

  describe "effective/1 — nil / no-budget handling (sensible + backward compatible)" do
    test "a goal with no groups yields an empty map" do
      assert GroupBudget.effective(Goal.new("g")) == %{}
    end

    test "a goal whose groups declare NO budgets yields every group mapped to nil" do
      groups = [
        Group.new("identity", "Identity"),
        Group.new("sign-up", "Sign Up", parent: "identity"),
        Group.new("register", "Register", parent: "sign-up")
      ]

      eff = GroupBudget.effective(goal(groups))
      assert eff == %{"identity" => nil, "sign-up" => nil, "register" => nil}
    end

    test "an unbounded leaf contributes nothing to its parent's sum" do
      # register(5) declared, verify undeclared (nil) -> sign-up sums only the
      # bounded child (5), not nil.
      groups = [
        Group.new("sign-up", "Sign Up"),
        Group.new("register", "Register", parent: "sign-up", budget: 5),
        Group.new("verify", "Verify", parent: "sign-up")
      ]

      eff = GroupBudget.effective(goal(groups))
      assert eff["verify"] == nil
      assert eff["sign-up"] == 5
    end

    test "a cap over an all-unbounded subtree stands alone (cap is the effective budget)" do
      # no leaf declares a budget, so the subtree sum is nil; identity's cap of 10
      # is the effective budget (not min(10, 0)).
      groups = [
        Group.new("identity", "Identity", budget: 10),
        Group.new("sign-up", "Sign Up", parent: "identity"),
        Group.new("register", "Register", parent: "sign-up")
      ]

      eff = GroupBudget.effective(goal(groups))
      assert eff["identity"] == 10
      assert eff["sign-up"] == nil
      assert eff["register"] == nil
    end
  end

  describe "effective/1 — tree-shape edge cases (mirror GroupTree)" do
    test "a group with an undeclared parent surfaces as a root (not dropped)" do
      groups = [Group.new("orphan", "Orphan", parent: "does-not-exist", budget: 4)]
      eff = GroupBudget.effective(goal(groups))
      assert eff == %{"orphan" => 4}
    end

    test "multiple roots each roll up independently" do
      eff = GroupBudget.effective(goal(three_level_groups()))
      # identity subtree and billing are independent roots
      assert eff["identity"] == 8
      assert eff["billing"] == 7
    end
  end

  describe "effective/1 — pure + deterministic" do
    test "the same goal always yields the same effective-budget map" do
      g = goal(three_level_groups(identity: [budget: 6]))
      assert GroupBudget.effective(g) == GroupBudget.effective(g)
    end
  end
end

defmodule Kazi.Goal.GroupTreeTest do
  use ExUnit.Case, async: true
  doctest Kazi.Goal.GroupTree

  alias Kazi.Goal
  alias Kazi.Goal.{Group, GroupTree}
  alias Kazi.{Predicate, PredicateResult, PredicateVector}

  # A 3-level pillar -> domain -> capability fixture (ADR-0020 §Context: the
  # taxonomy is reconstructed from flat `parent` links to arbitrary depth).
  #
  #   identity (pillar)
  #     sign-up (domain)
  #       register (capability)  -- p_register
  #       verify   (capability)  -- p_verify
  #   billing  (pillar, leaf, no predicates of its own besides one)
  defp three_level_goal do
    groups = [
      Group.new("identity", "Identity"),
      Group.new("sign-up", "Sign Up", parent: "identity"),
      Group.new("register", "Register", parent: "sign-up"),
      Group.new("verify", "Verify Email", parent: "sign-up"),
      Group.new("billing", "Billing")
    ]

    predicates = [
      Predicate.new(:p_register, :browser, group: "register", acceptance?: true),
      Predicate.new(:p_verify, :browser, group: "verify", acceptance?: true),
      Predicate.new(:p_identity_root, :tests, group: "identity"),
      Predicate.new(:p_billing, :http_probe, group: "billing")
    ]

    Goal.new("acme", groups: groups, predicates: predicates)
  end

  describe "tree/1" do
    test "reconstructs the tree from parent links to arbitrary (3-level) depth" do
      [identity, billing] = GroupTree.tree(three_level_goal())

      assert identity.group.id == "identity"
      assert billing.group.id == "billing"
      assert billing.children == []

      # identity -> sign-up
      assert [sign_up] = identity.children
      assert sign_up.group.id == "sign-up"

      # sign-up -> register, verify (two capabilities, third level)
      assert [register, verify] = sign_up.children
      assert register.group.id == "register"
      assert verify.group.id == "verify"
      assert register.children == []
      assert verify.children == []
    end

    test "preserves declared group order at every level (deterministic)" do
      goal = three_level_goal()
      assert GroupTree.tree(goal) == GroupTree.tree(goal)

      [identity, _billing] = GroupTree.tree(goal)
      [sign_up] = identity.children
      assert Enum.map(sign_up.children, & &1.group.id) == ["register", "verify"]
    end

    test "a group with an undeclared parent surfaces as a root (not dropped)" do
      groups = [Group.new("orphan", "Orphan", parent: "does-not-exist")]
      goal = Goal.new("g", groups: groups)

      assert [node] = GroupTree.tree(goal)
      assert node.group.id == "orphan"
      assert node.children == []
    end

    test "a goal with no groups yields an empty tree (backward compatible)" do
      assert GroupTree.tree(Goal.new("g")) == []

      ungrouped =
        Goal.new("g", predicates: [Predicate.new(:p, :tests)])

      assert GroupTree.tree(ungrouped) == []
    end
  end

  describe "rollup/2" do
    test "counts intended/built/pending for a group's OWN predicates" do
      goal =
        Goal.new("g",
          groups: [Group.new("billing", "Billing")],
          predicates: [
            Predicate.new(:b1, :tests, group: "billing"),
            Predicate.new(:b2, :tests, group: "billing")
          ]
        )

      roll = GroupTree.rollup(goal, %{b1: true, b2: false})
      assert roll["billing"] == %{intended: 2, built: 1, pending: 1}
    end

    test "rolls descendant predicates up into ancestors (recursive)" do
      # register: p_register pending; verify: p_verify built;
      # identity also has its own p_identity_root (built).
      verdicts = %{
        p_register: false,
        p_verify: true,
        p_identity_root: true,
        p_billing: true
      }

      roll = GroupTree.rollup(three_level_goal(), verdicts)

      # leaves: own predicates only
      assert roll["register"] == %{intended: 1, built: 0, pending: 1}
      assert roll["verify"] == %{intended: 1, built: 1, pending: 0}
      assert roll["billing"] == %{intended: 1, built: 1, pending: 0}

      # sign-up: register + verify (2 predicates, 1 built)
      assert roll["sign-up"] == %{intended: 2, built: 1, pending: 1}

      # identity: sign-up subtree (2) + its own p_identity_root (1) = 3 intended,
      # 2 built (p_verify, p_identity_root), 1 pending (p_register).
      assert roll["identity"] == %{intended: 3, built: 2, pending: 1}
    end

    test "intended == built + pending for every group" do
      roll = GroupTree.rollup(three_level_goal(), %{p_verify: true, p_billing: true})

      for {_id, %{intended: i, built: b, pending: p}} <- roll do
        assert i == b + p
      end
    end

    test "an unobserved predicate (absent verdict) is pending, not built" do
      roll = GroupTree.rollup(three_level_goal(), %{})

      # nothing observed -> everything intended, nothing built
      assert roll["identity"] == %{intended: 3, built: 0, pending: 3}
      assert roll["sign-up"] == %{intended: 2, built: 0, pending: 2}
      assert roll["billing"] == %{intended: 1, built: 0, pending: 1}
    end

    test "guards are included in a group's rollup (all_predicates)" do
      goal =
        Goal.new("g",
          groups: [Group.new("billing", "Billing")],
          predicates: [Predicate.new(:b1, :tests, group: "billing")],
          guards: [Predicate.new(:b_guard, :coverage, guard?: true, group: "billing")]
        )

      roll = GroupTree.rollup(goal, %{b1: true, b_guard: false})
      assert roll["billing"] == %{intended: 2, built: 1, pending: 1}
    end

    test "ungrouped predicates are not attributed to any group" do
      goal =
        Goal.new("g",
          groups: [Group.new("billing", "Billing")],
          predicates: [
            Predicate.new(:b1, :tests, group: "billing"),
            Predicate.new(:loose, :tests)
          ]
        )

      roll = GroupTree.rollup(goal, %{b1: true, loose: true})
      assert roll["billing"] == %{intended: 1, built: 1, pending: 0}
      refute Map.has_key?(roll, nil)
    end

    test "is deterministic — same goal + verdicts yield the same rollup" do
      goal = three_level_goal()
      verdicts = %{p_register: true, p_verify: false}
      assert GroupTree.rollup(goal, verdicts) == GroupTree.rollup(goal, verdicts)
    end

    test "defaults to all-pending when no verdicts are supplied" do
      roll = GroupTree.rollup(three_level_goal())
      assert roll["identity"] == %{intended: 3, built: 0, pending: 3}
    end

    test "a goal with no groups yields an empty rollup (backward compatible)" do
      assert GroupTree.rollup(Goal.new("g"), %{}) == %{}
      assert GroupTree.rollup(Goal.new("g")) == %{}
    end
  end

  describe "verdicts_from_vector/1" do
    test "maps a PredicateVector's pass/fail into id -> passing?" do
      vector =
        PredicateVector.new(%{
          p_register: PredicateResult.pass(),
          p_verify: PredicateResult.fail(),
          p_billing: PredicateResult.error()
        })

      verdicts = GroupTree.verdicts_from_vector(vector)
      assert verdicts == %{p_register: true, p_verify: false, p_billing: false}
    end

    test "feeds rollup/2 end-to-end from a vector" do
      vector =
        PredicateVector.new(%{
          p_register: PredicateResult.pass(),
          p_verify: PredicateResult.fail(),
          p_identity_root: PredicateResult.pass(),
          p_billing: PredicateResult.pass()
        })

      roll = GroupTree.rollup(three_level_goal(), GroupTree.verdicts_from_vector(vector))
      assert roll["identity"] == %{intended: 3, built: 2, pending: 1}
      assert roll["sign-up"] == %{intended: 2, built: 1, pending: 1}
    end
  end
end

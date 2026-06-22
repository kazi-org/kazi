defmodule Kazi.GoalTest do
  use ExUnit.Case, async: true
  doctest Kazi.Goal

  alias Kazi.{Budget, Goal, Predicate, Scope}

  describe "new/2" do
    test "builds a goal with required id and sensible defaults" do
      g = Goal.new("g1")
      assert g.id == "g1"
      assert g.name == nil
      assert g.predicates == []
      assert g.guards == []
      assert g.budget == %Budget{}
      assert g.scope == %Scope{}
      assert g.metadata == %{}
    end

    test "accepts predicates, guards, and metadata" do
      unit = Predicate.new(:unit, :tests)
      cov = Predicate.new(:cov, :coverage, guard?: true)

      g =
        Goal.new("ship",
          name: "Ship Slice 0",
          predicates: [unit],
          guards: [cov],
          metadata: %{owner: "kazi"}
        )

      assert g.predicates == [unit]
      assert g.guards == [cov]
      assert g.metadata == %{owner: "kazi"}
    end

    test "coerces budget keyword opts into a Budget struct" do
      g = Goal.new("g", budget: [max_iterations: 8, max_tokens: 100_000])
      assert %Budget{max_iterations: 8, max_tokens: 100_000} = g.budget
    end

    test "accepts a Budget struct directly" do
      budget = Budget.new(max_wall_clock_ms: 5_000)
      assert Goal.new("g", budget: budget).budget == budget
    end

    test "coerces scope keyword opts into a Scope struct" do
      g = Goal.new("g", scope: [workspace: "/tmp/repo", paths: ["lib/"]])
      assert %Scope{workspace: "/tmp/repo", paths: ["lib/"]} = g.scope
    end

    test "accepts a Scope struct directly" do
      scope = Scope.new(repo: "kazi-org/kazi")
      assert Goal.new("g", scope: scope).scope == scope
    end
  end

  describe "all_predicates/1" do
    test "concatenates predicates then guards" do
      unit = Predicate.new(:unit, :tests)
      live = Predicate.new(:live, :http_probe)
      cov = Predicate.new(:cov, :coverage, guard?: true)

      g = Goal.new("g", predicates: [unit, live], guards: [cov])
      assert Goal.all_predicates(g) == [unit, live, cov]
    end
  end

  test "enforces id on direct struct construction" do
    assert_raise ArgumentError, fn -> struct!(Goal, name: "no id") end
  end
end

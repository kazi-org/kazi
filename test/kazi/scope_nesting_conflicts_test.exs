defmodule Kazi.ScopeNestingConflictsTest do
  @moduledoc """
  T72.2 (ADR-0086 decision 2): `Kazi.Scope.nesting_conflicts/1` — the reusable,
  loader-agnostic check behind `kazi plan lint <roadmap>` (and, per the ADR, the
  same check `kazi plan render --tree` (T72.4) runs before writing a file).
  `entries` is a plain `{goal_id, roots}` list, so this suite drives the check
  directly without touching the roadmap loader or the CLI.
  """
  use ExUnit.Case, async: true

  alias Kazi.Scope

  describe "nesting_conflicts/1 — disjoint roots pass" do
    test "two goals with unrelated roots produce no conflicts" do
      assert Scope.nesting_conflicts([{"a", ["pkg/foo"]}, {"b", ["pkg/bar"]}]) == []
    end

    test "three mutually-disjoint goals produce no conflicts" do
      entries = [{"a", ["pkg/foo"]}, {"b", ["pkg/bar"]}, {"c", ["pkg/baz"]}]
      assert Scope.nesting_conflicts(entries) == []
    end
  end

  describe "nesting_conflicts/1 — a nested root pair refuses, naming both ids and the shared root" do
    test "a child root nested under a parent root conflicts, reporting the parent (shallower) root" do
      entries = [{"parent-goal", ["pkg/foo"]}, {"child-goal", ["pkg/foo/bar"]}]

      assert Scope.nesting_conflicts(entries) == [
               %{a: "parent-goal", b: "child-goal", root: "pkg/foo"}
             ]
    end

    test "order of declaration does not matter — the ancestor is still reported" do
      entries = [{"child-goal", ["pkg/foo/bar"]}, {"parent-goal", ["pkg/foo"]}]

      assert Scope.nesting_conflicts(entries) == [
               %{a: "child-goal", b: "parent-goal", root: "pkg/foo"}
             ]
    end

    test "a glob root nesting a plain child root also conflicts" do
      entries = [{"a", ["pkg/foo/**"]}, {"b", ["pkg/foo/bar/baz.ex"]}]

      assert [%{a: "a", b: "b", root: "pkg/foo/**"}] = Scope.nesting_conflicts(entries)
    end
  end

  describe "nesting_conflicts/1 — equal roots count as sharing a root" do
    test "two goals declaring the exact same root conflict" do
      entries = [{"a", ["pkg/foo"]}, {"b", ["pkg/foo"]}]

      assert Scope.nesting_conflicts(entries) == [%{a: "a", b: "b", root: "pkg/foo"}]
    end
  end

  describe "nesting_conflicts/1 — an unscoped goal never participates" do
    test "a goal with no declared roots is exempt, like Kazi.Fleet's inferred-edge rule" do
      entries = [{"unscoped", []}, {"a", ["pkg/foo"]}, {"b", ["pkg/foo/bar"]}]

      assert Scope.nesting_conflicts(entries) == [%{a: "a", b: "b", root: "pkg/foo"}]
    end

    test "every goal unscoped produces no conflicts at all" do
      assert Scope.nesting_conflicts([{"a", []}, {"b", []}]) == []
    end
  end

  describe "nesting_conflicts/1 — multiple roots per goal and multiple pairs" do
    test "finds a conflict even when only one of several roots nests" do
      entries = [{"a", ["lib/a", "pkg/foo"]}, {"b", ["lib/b", "pkg/foo/bar"]}]

      assert Scope.nesting_conflicts(entries) == [%{a: "a", b: "b", root: "pkg/foo"}]
    end

    test "reports a conflict for every pairwise-overlapping pair of goals, not just adjacent ones" do
      entries = [{"a", ["pkg/foo"]}, {"b", ["pkg/bar"]}, {"c", ["pkg/foo/deep"]}]

      assert Scope.nesting_conflicts(entries) == [%{a: "a", b: "c", root: "pkg/foo"}]
    end
  end
end

defmodule Kazi.ScopeRootsTest do
  @moduledoc """
  T72.1: `Kazi.Scope.roots/1` (write_paths-over-paths preference) and
  `Kazi.Scope.overlap?/2` (glob-aware, segment-based path overlap), the pieces
  `Kazi.Fleet`'s inferred scope-overlap edges are built from.
  """
  use ExUnit.Case, async: true

  alias Kazi.Scope

  describe "roots/1" do
    test "uses write_paths when only write_paths is declared" do
      scope = Scope.new(write_paths: ["a/**"])
      assert Scope.roots(scope) == ["a/**"]
    end

    test "prefers write_paths over paths when both are declared" do
      scope = Scope.new(write_paths: ["a/**"], paths: ["b/"])
      assert Scope.roots(scope) == ["a/**"]
    end

    test "falls back to paths when write_paths is empty" do
      scope = Scope.new(paths: ["b/"])
      assert Scope.roots(scope) == ["b/"]
    end

    test "is empty when neither is declared" do
      assert Scope.roots(Scope.new()) == []
    end
  end

  describe "overlap?/2" do
    test "a directory glob does not overlap a sibling with a shared string prefix" do
      refute Scope.overlap?(["pkg/foo/**"], ["pkg/foobar/**"])
    end

    test "a directory glob overlaps a file nested under it" do
      assert Scope.overlap?(["pkg/foo/**"], ["pkg/foo/bar/x.ex"])
    end

    test "a plain directory path overlaps a file nested under it" do
      assert Scope.overlap?(["pkg/foo"], ["pkg/foo/bar/x.ex"])
    end

    test "disjoint plain paths do not overlap" do
      refute Scope.overlap?(["lib/a"], ["lib/b"])
    end

    test "overlap is true if any pair across the two lists overlaps" do
      assert Scope.overlap?(["lib/a", "pkg/foo/**"], ["lib/b", "pkg/foo/bar/x.ex"])
    end
  end
end

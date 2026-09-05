defmodule Kazi.ScopeDiffTest do
  @moduledoc """
  ADR-0085: `Kazi.ScopeDiff.under_any?/2` gained directory-glob-suffix support
  (`/**`/`/*`) so `[scope].forbidden_paths` can be authored either as an exact
  path or a directory glob, matching `Kazi.Scope.overlap?/2`'s existing
  authoring convention. The pre-existing exact-path/directory-prefix matching
  (issue #860's `deny`) is pinned unchanged alongside it.
  """
  use ExUnit.Case, async: true

  alias Kazi.ScopeDiff

  describe "under_any?/2 — pre-existing exact/prefix matching (regression, issue #860)" do
    test "an exact path match" do
      assert ScopeDiff.under_any?("docs/plan.md", ["docs/plan.md"])
    end

    test "a directory prefix match" do
      assert ScopeDiff.under_any?("ios/Auth.plist", ["ios/"])
      assert ScopeDiff.under_any?("ios/Auth.plist", ["ios"])
    end

    test "a sibling file is not matched by an exact-file prefix" do
      refute ScopeDiff.under_any?("ios/Other.plist", ["ios/Auth.plist"])
    end

    test "no match" do
      refute ScopeDiff.under_any?("docs/other.md", ["docs/plan.md"])
    end
  end

  describe "under_any?/2 — new /** and /* directory-glob suffix (ADR-0085)" do
    test "a /** suffix matches anything under the directory" do
      assert ScopeDiff.under_any?("docs/plans/E70.md", ["docs/plans/**"])
      assert ScopeDiff.under_any?("docs/plans/archive/E50.md", ["docs/plans/**"])
    end

    test "a /* suffix matches anything under the directory" do
      assert ScopeDiff.under_any?("docs/plans/E70.md", ["docs/plans/*"])
    end

    test "a /** suffix still matches the bare directory path itself" do
      assert ScopeDiff.under_any?("docs/plans", ["docs/plans/**"])
    end

    test "a /** suffix does not match a same-prefix sibling directory" do
      refute ScopeDiff.under_any?("docs/plans-archive/E50.md", ["docs/plans/**"])
    end
  end
end

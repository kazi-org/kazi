defmodule Kazi.PredicateTest do
  use ExUnit.Case, async: true
  doctest Kazi.Predicate

  alias Kazi.Predicate

  describe "new/3" do
    test "builds a predicate with required id and kind" do
      p = Predicate.new(:unit, :tests)
      assert p.id == :unit
      assert p.kind == :tests
      assert p.config == %{}
      assert p.guard? == false
      assert p.description == nil
    end

    test "accepts config, description, and guard? opts" do
      p =
        Predicate.new("live-probe", :http_probe,
          config: %{url: "https://example.test/health"},
          description: "service answers 200",
          guard?: false
        )

      assert p.id == "live-probe"
      assert p.config == %{url: "https://example.test/health"}
      assert p.description == "service answers 200"
    end

    test "marks guards" do
      p = Predicate.new(:coverage, :coverage, guard?: true)
      assert Predicate.guard?(p)
    end

    test "group defaults to nil (ungrouped, backward-compatible)" do
      assert Predicate.new(:unit, :tests).group == nil
    end

    test "accepts an optional declared group id (T12.2)" do
      p = Predicate.new(:signup, :browser, group: "identity-access")
      assert p.group == "identity-access"
    end
  end

  test "enforces id and kind keys on direct struct construction" do
    assert_raise ArgumentError, fn ->
      struct!(Predicate, description: "no id or kind")
    end
  end

  test "guard?/1 reflects the flag" do
    refute Predicate.guard?(Predicate.new(:unit, :tests))
    assert Predicate.guard?(Predicate.new(:unit, :tests, guard?: true))
  end
end

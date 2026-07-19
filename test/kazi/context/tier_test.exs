defmodule Kazi.Context.TierTest do
  @moduledoc """
  T36.3 (ADR-0047 §2): the context-budget tier ladder — names tiers 0–4, defaults
  to tier 1, and exposes the cumulative feature set each tier assembles. Pure and
  total: a malformed `:context_tier` never crashes, it falls back to the default.
  """
  use ExUnit.Case, async: true
  doctest Kazi.Context.Tier

  alias Kazi.Context.Tier

  describe "default / range" do
    test "the default tier is 1 (evidence + cached orientation)" do
      assert Tier.default() == 1
    end

    test "the defined range is 0..4" do
      assert Tier.range() == 0..4
    end

    test "the opt key is :context_tier" do
      assert Tier.opt_key() == :context_tier
    end
  end

  describe "valid? / normalize" do
    test "every tier 0..4 is valid; everything else is not" do
      for tier <- 0..4, do: assert(Tier.valid?(tier))
      refute Tier.valid?(-1)
      refute Tier.valid?(5)
      refute Tier.valid?("1")
      refute Tier.valid?(nil)
      refute Tier.valid?(1.0)
    end

    test "normalize keeps a valid tier and defaults a malformed one" do
      for tier <- 0..4, do: assert(Tier.normalize(tier) == tier)
      assert Tier.normalize(-1) == 1
      assert Tier.normalize(42) == 1
      assert Tier.normalize(:bogus) == 1
      assert Tier.normalize(nil) == 1
    end
  end

  describe "resolve/1 — from adapter opts" do
    test "absent :context_tier defaults to tier 1" do
      assert Tier.resolve([]) == 1
      assert Tier.resolve(graph_source: :whatever) == 1
    end

    test "reads and normalizes the :context_tier opt" do
      assert Tier.resolve(context_tier: 0) == 0
      assert Tier.resolve(context_tier: 2) == 2
      assert Tier.resolve(context_tier: 4) == 4
      # A malformed selection conservatively assembles the default tier.
      assert Tier.resolve(context_tier: 99) == 1
      assert Tier.resolve(context_tier: "2") == 1
    end

    test "a non-list is the default (defensive)" do
      assert Tier.resolve(nil) == 1
      assert Tier.resolve(%{context_tier: 3}) == 1
    end
  end

  describe "features/1 — the cumulative ladder" do
    test "tier 0 is evidence-only (no orientation, graph, retrieval, snapshot)" do
      assert Tier.features(0) == %{
               orientation: false,
               graph: false,
               retrieval: false,
               snapshot: false
             }
    end

    test "tier 1 (default) adds cached orientation only" do
      assert Tier.features(1) == %{
               orientation: true,
               graph: false,
               retrieval: false,
               snapshot: false
             }
    end

    test "tier 2 adds the graph on top of orientation" do
      assert Tier.features(2) == %{
               orientation: true,
               graph: true,
               retrieval: false,
               snapshot: false
             }
    end

    test "tier 3 adds retrieval, tier 4 adds the compact snapshot — cumulative" do
      assert Tier.features(3) == %{
               orientation: true,
               graph: true,
               retrieval: true,
               snapshot: false
             }

      assert Tier.features(4) == %{
               orientation: true,
               graph: true,
               retrieval: true,
               snapshot: true
             }
    end

    test "each higher tier is a superset of the lower tier's enabled features" do
      enabled = fn tier ->
        Tier.features(tier)
        |> Enum.filter(fn {_k, v} -> v end)
        |> Enum.map(&elem(&1, 0))
        |> MapSet.new()
      end

      for tier <- 0..3 do
        assert MapSet.subset?(enabled.(tier), enabled.(tier + 1)),
               "tier #{tier} features must be a subset of tier #{tier + 1}"
      end
    end

    test "features/1 normalizes a malformed tier (total)" do
      assert Tier.features(99) == Tier.features(1)
    end
  end

  describe "feature predicates" do
    test "orientation? is true for tier >= 1" do
      refute Tier.orientation?(0)
      for tier <- 1..4, do: assert(Tier.orientation?(tier))
    end

    test "graph? is true for tier >= 2" do
      for tier <- 0..1, do: refute(Tier.graph?(tier))
      for tier <- 2..4, do: assert(Tier.graph?(tier))
    end

    test "retrieval? is true for tier >= 3" do
      for tier <- 0..2, do: refute(Tier.retrieval?(tier))
      for tier <- 3..4, do: assert(Tier.retrieval?(tier))
    end

    test "snapshot? is true only for tier 4" do
      for tier <- 0..3, do: refute(Tier.snapshot?(tier))
      assert Tier.snapshot?(4)
    end
  end
end

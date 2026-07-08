defmodule Kazi.Economy.ModelIdNormalizationTest do
  # Model ID normalization (ADR-TBD): normalize model IDs to canonical form
  # so that common variations (case, version suffixes, whitespace) resolve to the
  # same priced entry. This decouples the price table from minor provider
  # variability while keeping the honest-unknown discipline: a model the
  # normalized form doesn't match is still unknown.
  #
  # async: true — pure functions, no I/O.
  use ExUnit.Case, async: true

  alias Kazi.Economy.ModelIdNormalization

  describe "normalize/1 — canonical form for model IDs" do
    test "returns the model as-is when already canonical (lowercase, no version)" do
      assert ModelIdNormalization.normalize("claude-opus-4-8") == "claude-opus-4-8"
      assert ModelIdNormalization.normalize("claude-haiku-4-5") == "claude-haiku-4-5"
      assert ModelIdNormalization.normalize("claude-sonnet-5") == "claude-sonnet-5"
    end

    test "lowercases uppercase model IDs" do
      assert ModelIdNormalization.normalize("CLAUDE-OPUS-4-8") == "claude-opus-4-8"
      assert ModelIdNormalization.normalize("Claude-Opus-4-8") == "claude-opus-4-8"
      assert ModelIdNormalization.normalize("CLAUDE-SONNET-5") == "claude-sonnet-5"
    end

    test "strips trailing version dates (YYYYMMDD suffix after a dash)" do
      assert ModelIdNormalization.normalize("claude-opus-4-8-20260101") == "claude-opus-4-8"
      assert ModelIdNormalization.normalize("claude-sonnet-5-20260630") == "claude-sonnet-5"
      assert ModelIdNormalization.normalize("claude-haiku-4-5-20250101") == "claude-haiku-4-5"
    end

    test "combines multiple normalizations (case + version suffix)" do
      assert ModelIdNormalization.normalize("CLAUDE-OPUS-4-8-20260101") ==
               "claude-opus-4-8"

      assert ModelIdNormalization.normalize("Claude-Sonnet-5-20260630") == "claude-sonnet-5"
    end

    test "trims leading/trailing whitespace" do
      assert ModelIdNormalization.normalize("  claude-opus-4-8  ") == "claude-opus-4-8"
      assert ModelIdNormalization.normalize("\tclaude-haiku-4-5\n") == "claude-haiku-4-5"
    end

    test "returns nil for non-binary inputs (non-string models)" do
      assert ModelIdNormalization.normalize(nil) == nil
      assert ModelIdNormalization.normalize(:claude) == nil
      assert ModelIdNormalization.normalize(42) == nil
    end

    test "returns empty string as-is (invalid but doesn't crash)" do
      assert ModelIdNormalization.normalize("") == ""
    end
  end

  describe "normalize_and_lookup/2 — normalized lookup against a map" do
    setup do
      # A minimal price map for testing
      models = %{
        "claude-opus-4-8" => :opus,
        "claude-sonnet-5" => :sonnet,
        "claude-haiku-4-5" => :haiku
      }

      {:ok, models: models}
    end

    test "resolves a canonical model", %{models: models} do
      assert ModelIdNormalization.normalize_and_lookup("claude-opus-4-8", models) ==
               {:ok, :opus}
    end

    test "resolves an uppercase variant", %{models: models} do
      assert ModelIdNormalization.normalize_and_lookup("CLAUDE-OPUS-4-8", models) ==
               {:ok, :opus}
    end

    test "resolves a version-dated variant", %{models: models} do
      assert ModelIdNormalization.normalize_and_lookup(
               "claude-sonnet-5-20260630",
               models
             ) == {:ok, :sonnet}
    end

    test "resolves a fully-mangled variant (case + version + whitespace)", %{
      models: models
    } do
      assert ModelIdNormalization.normalize_and_lookup(
               "  CLAUDE-HAIKU-4-5-20250101\n",
               models
             ) == {:ok, :haiku}
    end

    test "returns :error for a model not in the map, even after normalization", %{
      models: models
    } do
      assert ModelIdNormalization.normalize_and_lookup("claude-unknown-model", models) ==
               :error
    end

    test "returns :error for nil input" do
      assert ModelIdNormalization.normalize_and_lookup(nil, %{"claude-opus-4-8" => :opus}) ==
               :error
    end
  end
end

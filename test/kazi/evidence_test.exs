defmodule Kazi.EvidenceTest do
  @moduledoc """
  Unit tests for the structured evidence item — the LSP-`Diagnostic`-shaped
  envelope every provider maps onto (ADR-0041 decision 3, T32.2).
  """
  use ExUnit.Case, async: true
  doctest Kazi.Evidence

  alias Kazi.Evidence

  describe "new/1" do
    test "builds from a keyword list, defaulting absent fields to nil" do
      item = Evidence.new(file: "lib/a.ex", line: 12, rule: "no-unused", level: :warning)

      assert item.file == "lib/a.ex"
      assert item.line == 12
      assert item.rule == "no-unused"
      assert item.level == :warning
      assert item.col == nil
      assert item.message == nil
      assert item.expected == nil
      assert item.got == nil
    end

    test "builds from a map and ignores unknown keys" do
      item = Evidence.new(%{message: "boom", bogus: "ignored"})

      assert item.message == "boom"
      refute Map.has_key?(item, :bogus)
    end
  end

  describe "to_map/1 — JSON-safe, compact" do
    test "omits nil fields and stringifies the level atom" do
      item = Evidence.new(file: "a.ex", line: 3, level: :error)

      assert Evidence.to_map(item) == %{"file" => "a.ex", "line" => 3, "level" => "error"}
    end

    test "a fully-populated item round-trips every field as JSON scalars" do
      item =
        Evidence.new(
          file: "lib/a.ex",
          line: 7,
          col: 4,
          rule: "Mod.test",
          level: :error,
          message: "expected 1, got 2",
          expected: "1",
          got: "2"
        )

      map = Evidence.to_map(item)

      assert map == %{
               "file" => "lib/a.ex",
               "line" => 7,
               "col" => 4,
               "rule" => "Mod.test",
               "level" => "error",
               "message" => "expected 1, got 2",
               "expected" => "1",
               "got" => "2"
             }

      # JSON-safe by construction: encodes without the read-model's deep-sanitize.
      assert {:ok, _} = Jason.encode(map)
    end

    test "an empty item serializes to an empty map" do
      assert Evidence.to_map(Evidence.new([])) == %{}
    end
  end

  describe "from_map/1" do
    test "is the inverse of to_map/1 (string keys, decoded level)" do
      item =
        Evidence.new(
          file: "a.ex",
          line: 9,
          col: 2,
          rule: "r",
          level: :warning,
          message: "m",
          expected: "x",
          got: "y"
        )

      assert Evidence.from_map(Evidence.to_map(item)) == item
    end

    test "tolerates a partial map and an unknown level" do
      item = Evidence.from_map(%{"file" => "a.ex", "level" => "nope"})

      assert item.file == "a.ex"
      assert item.level == nil
    end
  end
end

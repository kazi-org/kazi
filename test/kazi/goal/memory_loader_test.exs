defmodule Kazi.Goal.MemoryLoaderTest do
  @moduledoc """
  ADR-0062: the loader maps the optional `[memory]` table's `corpus` key onto
  `Goal.memory_corpus`. Absent -> `nil` ("use the built-in default corpus"),
  byte-identical to a goal-file authored before ADR-0062 (no `[memory]` table
  at all). An explicit `corpus = []` opts a goal OUT of recall entirely.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader

  defp base_data(extra \\ %{}) do
    Map.merge(
      %{
        "id" => "g",
        "predicate" => [%{"id" => "p", "provider" => "test_runner"}]
      },
      extra
    )
  end

  test "no [memory] table -> memory_corpus defaults to nil (use the default corpus)" do
    assert {:ok, %Goal{memory_corpus: nil}} = Loader.from_map(base_data())
  end

  test "an empty [memory] table (no corpus key) also defaults to nil" do
    assert {:ok, %Goal{memory_corpus: nil}} = Loader.from_map(base_data(%{"memory" => %{}}))
  end

  test "[memory] corpus overrides the default corpus" do
    assert {:ok, %Goal{memory_corpus: ["docs/**/*.md"]}} =
             Loader.from_map(base_data(%{"memory" => %{"corpus" => ["docs/**/*.md"]}}))
  end

  test "an explicit empty corpus opts the goal out of recall" do
    assert {:ok, %Goal{memory_corpus: []}} =
             Loader.from_map(base_data(%{"memory" => %{"corpus" => []}}))
  end

  test "a non-string-list corpus is a load error" do
    assert {:error, reason} =
             Loader.from_map(base_data(%{"memory" => %{"corpus" => [1, 2]}}))

    assert reason =~ "\"corpus\""
    assert reason =~ "array of strings"
  end

  test "a non-table [memory] is a load error" do
    assert {:error, reason} = Loader.from_map(base_data(%{"memory" => "oops"}))
    assert reason =~ "[memory]"
  end
end

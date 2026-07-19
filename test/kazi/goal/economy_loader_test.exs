defmodule Kazi.Goal.EconomyLoaderTest do
  @moduledoc """
  T48.11 (ADR-0058 §3): the loader maps the optional `[economy]` table's
  `debrief` boolean onto `Goal.debrief`. Absent -> `false`, byte-identical to a
  goal-file authored before T48.11 (no `[economy]` table at all).
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

  test "no [economy] table -> debrief defaults to false" do
    assert {:ok, %Goal{debrief: false}} = Loader.from_map(base_data())
  end

  test "[economy] debrief = true opts the goal in" do
    assert {:ok, %Goal{debrief: true}} =
             Loader.from_map(base_data(%{"economy" => %{"debrief" => true}}))
  end

  test "[economy] debrief = false is explicit and equivalent to absent" do
    assert {:ok, %Goal{debrief: false}} =
             Loader.from_map(base_data(%{"economy" => %{"debrief" => false}}))
  end

  test "an empty [economy] table defaults debrief to false" do
    assert {:ok, %Goal{debrief: false}} = Loader.from_map(base_data(%{"economy" => %{}}))
  end

  test "a non-boolean debrief is a load error" do
    assert {:error, reason} =
             Loader.from_map(base_data(%{"economy" => %{"debrief" => "yes"}}))

    assert reason =~ "\"debrief\""
    assert reason =~ "boolean"
  end

  test "a non-table [economy] is a load error" do
    assert {:error, reason} = Loader.from_map(base_data(%{"economy" => "oops"}))
    assert reason =~ "[economy]"
  end
end

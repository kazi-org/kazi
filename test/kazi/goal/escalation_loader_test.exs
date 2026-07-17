defmodule Kazi.Goal.EscalationLoaderTest do
  @moduledoc """
  T45.7 (ADR-0056 decision 5): the loader maps the optional `[escalation]` table
  onto `Goal.escalation`. Absent resolves to `Goal.default_escalation/0` (an empty
  ladder — no escalation, byte-identical to today); the field-type guards fail
  loudly at load.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader

  defp base_data(extra \\ %{}) do
    Map.merge(
      %{"id" => "g", "predicate" => [%{"id" => "p", "provider" => "test_runner"}]},
      extra
    )
  end

  defp load(extra), do: Loader.from_map(base_data(extra))

  test "no [escalation] table -> the default (empty ladder, no escalation)" do
    assert {:ok, %Goal{escalation: escalation}} = Loader.from_map(base_data())
    assert escalation == Goal.default_escalation()
    assert escalation == %{ladder: [], max_rungs: nil}
  end

  test "an explicit ladder is stored verbatim" do
    assert {:ok, %Goal{escalation: escalation}} =
             load(%{"escalation" => %{"ladder" => ["claude-sonnet-5", "claude-opus-4-8"]}})

    assert escalation == %{ladder: ["claude-sonnet-5", "claude-opus-4-8"], max_rungs: nil}
  end

  test "a present block with no ladder defaults to the documented three-rung ladder" do
    assert {:ok, %Goal{escalation: %{ladder: ladder}}} = load(%{"escalation" => %{}})
    assert ladder == ["claude-haiku-4-5", "claude-sonnet-5", "claude-opus-4-8"]
  end

  test "max_rungs is parsed" do
    assert {:ok, %Goal{escalation: %{max_rungs: 2}}} =
             load(%{"escalation" => %{"ladder" => ["a", "b", "c"], "max_rungs" => 2}})
  end

  test "an empty ladder is a load error (a declared block must name models)" do
    assert {:error, reason} = load(%{"escalation" => %{"ladder" => []}})
    assert reason =~ "[escalation]"
    assert reason =~ "ladder"
  end

  test "a non-string ladder entry is a load error" do
    assert {:error, reason} = load(%{"escalation" => %{"ladder" => ["ok", 7]}})
    assert reason =~ "[escalation]"
    assert reason =~ "ladder"
  end

  test "a non-positive max_rungs is a load error" do
    assert {:error, reason} = load(%{"escalation" => %{"ladder" => ["a"], "max_rungs" => 0}})
    assert reason =~ "max_rungs"
  end

  test "a non-table [escalation] is a load error" do
    assert {:error, reason} = load(%{"escalation" => "oops"})
    assert reason =~ "[escalation]"
  end

  test "`kazi schema escalation` has a documented block schema" do
    assert {:ok, schema} = Kazi.Predicate.Schema.fetch("escalation")
    assert schema.kind == "escalation"
    assert schema.description != ""
    assert "escalation" in Kazi.Predicate.Schema.kinds()

    names = schema.keys |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["ladder", "max_rungs"]
  end
end

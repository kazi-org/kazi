defmodule Kazi.Goal.ConventionsLoaderTest do
  @moduledoc """
  T44.4 (ADR-0055 decision 4b): the loader maps the optional `[conventions]` table
  onto `Goal.conventions`. Absent resolves to `Goal.default_conventions/0` (process
  contract ON, no extra rules); the field-type guards fail loudly at load.
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

  test "no [conventions] table -> the default (process contract on, no extra rules)" do
    assert {:ok, %Goal{conventions: conventions}} = Loader.from_map(base_data())
    assert conventions == Goal.default_conventions()
    assert conventions == %{process_contract: true, extra_rules: []}
  end

  test "process_contract = false is parsed" do
    assert {:ok, %Goal{conventions: %{process_contract: false, extra_rules: []}}} =
             load(%{"conventions" => %{"process_contract" => false}})
  end

  test "extra_rules are stored verbatim, in order" do
    assert {:ok, %Goal{conventions: conventions}} =
             load(%{"conventions" => %{"extra_rules" => ["a", "b", "c"]}})

    assert conventions == %{process_contract: true, extra_rules: ["a", "b", "c"]}
  end

  test "an empty [conventions] table keeps the defaults" do
    {:ok, absent} = Loader.from_map(base_data())
    {:ok, empty} = load(%{"conventions" => %{}})
    assert empty.conventions == absent.conventions
  end

  test "a non-boolean process_contract is a load error naming the field" do
    assert {:error, reason} = load(%{"conventions" => %{"process_contract" => "yes"}})
    assert reason =~ "[conventions]"
    assert reason =~ "process_contract"
    assert reason =~ "boolean"
  end

  test "a non-list extra_rules is a load error naming the field" do
    assert {:error, reason} = load(%{"conventions" => %{"extra_rules" => "not a list"}})
    assert reason =~ "[conventions]"
    assert reason =~ "extra_rules"
  end

  test "a non-string extra_rules entry is a load error" do
    assert {:error, reason} = load(%{"conventions" => %{"extra_rules" => ["ok", 7]}})
    assert reason =~ "extra_rules"
    assert reason =~ "strings"
  end

  test "a non-table [conventions] is a load error" do
    assert {:error, reason} = load(%{"conventions" => "oops"})
    assert reason =~ "[conventions]"
  end
end

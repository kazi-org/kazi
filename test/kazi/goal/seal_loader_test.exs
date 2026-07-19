defmodule Kazi.Goal.SealLoaderTest do
  @moduledoc """
  ADR-0080 (#1520): the loader maps the optional `[seal]` table onto `Goal.seal`.
  Absent resolves to `nil` (no block — only the goal-file is implicitly sealed,
  byte-identical to pre-ADR-0080); the field-type guards fail loudly at load.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Seal}
  alias Kazi.Goal.Loader

  defp base_data(extra \\ %{}) do
    Map.merge(
      %{"id" => "g", "predicate" => [%{"id" => "p", "provider" => "test_runner"}]},
      extra
    )
  end

  defp load(extra), do: Loader.from_map(base_data(extra))

  test "no [seal] table -> nil (only the goal-file is implicitly sealed)" do
    assert {:ok, %Goal{seal: nil}} = Loader.from_map(base_data())
  end

  test "sealed_inputs + mutable_inputs are parsed onto a %Seal{}" do
    assert {:ok, %Goal{seal: %Seal{} = seal}} =
             load(%{
               "seal" => %{
                 "sealed_inputs" => ["checks/manifest.toml", "checks/reference/**/*.png"],
                 "mutable_inputs" => ["checks/reference/regen.png"]
               }
             })

    assert seal.enabled == true
    assert seal.sealed_inputs == ["checks/manifest.toml", "checks/reference/**/*.png"]
    assert seal.mutable_inputs == ["checks/reference/regen.png"]
  end

  test "enabled = false is the whole-run opt-out" do
    assert {:ok, %Goal{seal: %Seal{enabled: false}}} =
             load(%{"seal" => %{"enabled" => false}})
  end

  test "a present [seal] with no keys defaults enabled true, empty lists" do
    assert {:ok, %Goal{seal: %Seal{enabled: true, sealed_inputs: [], mutable_inputs: []}}} =
             load(%{"seal" => %{}})
  end

  test "sealed_inputs must be a list of strings" do
    assert {:error, msg} = load(%{"seal" => %{"sealed_inputs" => "checks/manifest.toml"}})
    assert msg =~ "sealed_inputs"

    assert {:error, msg2} = load(%{"seal" => %{"sealed_inputs" => [1, 2]}})
    assert msg2 =~ "sealed_inputs"
  end

  test "enabled must be a boolean" do
    assert {:error, msg} = load(%{"seal" => %{"enabled" => "yes"}})
    assert msg =~ "enabled"
  end

  test "a non-table [seal] fails loudly" do
    assert {:error, msg} = load(%{"seal" => "nope"})
    assert msg =~ "[seal] must be a table"
  end
end

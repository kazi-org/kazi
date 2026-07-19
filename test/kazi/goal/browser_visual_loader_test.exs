defmodule Kazi.Goal.BrowserVisualLoaderTest do
  @moduledoc """
  T43.3 (UC-056): the loader knows the `visual` browser assertion type and
  validates its `name` (required — the baseline id) and `threshold` (a [0,1]
  fraction) at load, so a mis-declared visual gate fails loudly instead of at
  dispatch.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Goal.Loader

  defp load(assertions) do
    Loader.from_map(%{
      "id" => "g",
      "predicate" => [
        %{
          "id" => "p",
          "provider" => "browser",
          "url" => "https://example.test/app",
          "assertions" => assertions
        }
      ]
    })
  end

  test "a visual assertion with a name loads" do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :browser}]}} =
             load([%{"type" => "visual", "name" => "home-hero"}])
  end

  test "a visual assertion with name + selector + threshold loads" do
    assert {:ok, _} =
             load([
               %{"type" => "visual", "name" => "hero", "selector" => "#hero", "threshold" => 0.02}
             ])
  end

  test "a visual assertion with no name is a load error" do
    assert {:error, msg} = load([%{"type" => "visual", "selector" => "#hero"}])
    assert msg =~ "name"
  end

  test "an empty name is a load error" do
    assert {:error, msg} = load([%{"type" => "visual", "name" => ""}])
    assert msg =~ "name"
  end

  test "a threshold above 1 is a load error" do
    assert {:error, msg} = load([%{"type" => "visual", "name" => "h", "threshold" => 1.5}])
    assert msg =~ "threshold"
  end

  test "a non-numeric threshold is a load error" do
    assert {:error, msg} = load([%{"type" => "visual", "name" => "h", "threshold" => "loose"}])
    assert msg =~ "threshold"
  end

  test "visual is a valid type (a typo names the set including it)" do
    assert {:error, msg} = load([%{"type" => "visul", "name" => "h"}])
    assert msg =~ "visual"
  end
end

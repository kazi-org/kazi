defmodule Kazi.Goal.BrowserA11yLoaderTest do
  @moduledoc """
  T43.2 (UC-056): the loader knows the `a11y` browser assertion type and validates
  its `severity` / `max_violations` keys, so a mis-declared a11y gate (an unknown
  severity, a negative/float budget) fails loudly at LOAD instead of by burning the
  loop's budget at dispatch (the L-0018 class).
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

  test "an a11y assertion with no keys loads (runner defaults apply)" do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :browser}]}} = load([%{"type" => "a11y"}])
  end

  test "a11y with a valid severity + max_violations loads" do
    assert {:ok, _} =
             load([%{"type" => "a11y", "severity" => "critical", "max_violations" => 3}])
  end

  test "an unknown a11y severity is a load error" do
    assert {:error, msg} = load([%{"type" => "a11y", "severity" => "blocker"}])
    assert msg =~ "severity"
  end

  test "a negative max_violations is a load error" do
    assert {:error, msg} = load([%{"type" => "a11y", "max_violations" => -1}])
    assert msg =~ "max_violations"
  end

  test "a non-integer max_violations is a load error" do
    assert {:error, msg} = load([%{"type" => "a11y", "max_violations" => 1.5}])
    assert msg =~ "max_violations"
  end

  test "a11y is listed as a valid type (a typo names the set including it)" do
    assert {:error, msg} = load([%{"type" => "a1y"}])
    assert msg =~ "a11y"
  end
end

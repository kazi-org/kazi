defmodule Kazi.Goal.BrowserFormValidationLoaderTest do
  @moduledoc """
  T43.4 (UC-056): the loader knows the DOM-state assertion types (`attr`, `count`,
  `enabled`, `field_value`, `form_validation`) and validates the keys whose
  mis-declaration would otherwise become a permanent :fail at dispatch (the L-0018
  / ADR-0058 config-error-as-fail shape). A string count, a "false" string flag,
  an attr with no `name`, and a form_validation that checks nothing all fail loudly
  at LOAD.
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
          "url" => "https://example.test/signup",
          "assertions" => assertions
        }
      ]
    })
  end

  defp loads?(assertions) do
    match?({:ok, %Goal{predicates: [%Predicate{kind: :browser}]}}, load(assertions))
  end

  describe "count" do
    test "a non-negative integer loads" do
      assert loads?([%{"type" => "count", "selector" => "li", "expected" => 3}])
      assert loads?([%{"type" => "count", "selector" => "li", "expected" => 0}])
    end

    test "a string expected is a load error (would compare unequal to a JS number forever)" do
      assert {:error, msg} = load([%{"type" => "count", "selector" => "li", "expected" => "3"}])
      assert msg =~ "count"
      assert msg =~ "non-negative integer"
    end

    test "a negative expected is a load error" do
      assert {:error, msg} = load([%{"type" => "count", "selector" => "li", "expected" => -1}])
      assert msg =~ "count"
    end
  end

  describe "enabled" do
    test "a boolean expected loads, and omitting it loads (runner default true)" do
      assert loads?([%{"type" => "enabled", "selector" => "button", "expected" => false}])
      assert loads?([%{"type" => "enabled", "selector" => "button"}])
    end

    test "a string 'false' is a load error (truthy in JS — the inverse of intent)" do
      assert {:error, msg} =
               load([%{"type" => "enabled", "selector" => "button", "expected" => "false"}])

      assert msg =~ "enabled"
      assert msg =~ "boolean"
    end
  end

  describe "attr" do
    test "a non-empty name loads" do
      assert loads?([
               %{
                 "type" => "attr",
                 "selector" => "#e",
                 "name" => "aria-invalid",
                 "expected" => "true"
               }
             ])
    end

    test "a missing name is a load error" do
      assert {:error, msg} = load([%{"type" => "attr", "selector" => "#e", "expected" => "true"}])
      assert msg =~ "attr"
      assert msg =~ "name"
    end
  end

  describe "field_value" do
    test "loads (no special key validation beyond a known type)" do
      assert loads?([%{"type" => "field_value", "selector" => "#email", "expected" => "a@b.com"}])
    end
  end

  describe "form_validation" do
    test "loads when at least one sub-check is requested" do
      assert loads?([
               %{
                 "type" => "form_validation",
                 "submit_selector" => "button[type=submit]",
                 "invalid" => [%{"selector" => "#email", "value" => "nope"}]
               }
             ])

      assert loads?([%{"type" => "form_validation", "success_url" => "/welcome"}])
    end

    test "a form_validation that requests NO sub-check is a load error (checks nothing)" do
      assert {:error, msg} =
               load([%{"type" => "form_validation", "invalid" => [%{"selector" => "#e"}]}])

      assert msg =~ "form_validation"
      assert msg =~ "no sub-check"
    end
  end

  # The shipped example is documentation that runs: if it stops loading, the docs
  # lie. Pin it here so it can never silently break (the same guard adopt_e2e keeps
  # on its example goal-file).
  test "the shipped priv/examples/form_validation.toml example loads" do
    path = Path.join([File.cwd!(), "priv", "examples", "form_validation.toml"])
    assert {:ok, %Goal{predicates: [%Predicate{kind: :browser}]}} = Loader.load(path)
  end
end

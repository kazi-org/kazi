defmodule Kazi.Goal.CustomScriptLoaderTest do
  @moduledoc """
  T32.1 (ADR-0040): the loader maps `provider = "custom_script"` to the
  `:custom_script` kind and VALIDATES its verdict/evidence keys, so a mis-declared
  gate fails loudly at load time rather than silently at dispatch.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Goal.Loader

  defp load(predicate_toml) do
    Loader.from_map(%{
      "id" => "g",
      "predicate" => [Map.merge(%{"id" => "p", "provider" => "custom_script"}, predicate_toml)]
    })
  end

  test "a minimal exit_zero custom_script predicate loads" do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :custom_script, config: config}]}} =
             load(%{"cmd" => "go", "args" => ["test", "./..."]})

    assert config.cmd == "go"
  end

  test "a json verdict with path + pass_when loads" do
    assert {:ok, _} =
             load(%{
               "cmd" => "semgrep",
               "verdict" => "json",
               "path" => "$.runs[0].results",
               "pass_when" => "== 0"
             })
  end

  test "a missing cmd is a load error" do
    assert {:error, msg} = load(%{"verdict" => "exit_zero"})
    assert msg =~ "requires a non-empty string \"cmd\""
  end

  test "an unknown verdict is a load error" do
    assert {:error, msg} = load(%{"cmd" => "x", "verdict" => "maybe"})
    assert msg =~ "unknown verdict"
  end

  test "a json verdict missing path is a load error" do
    assert {:error, msg} = load(%{"cmd" => "x", "verdict" => "json", "pass_when" => "== 0"})
    assert msg =~ "verdict \"json\" requires a non-empty string \"path\""
  end

  test "a json verdict with a malformed pass_when is a load error" do
    assert {:error, msg} =
             load(%{"cmd" => "x", "verdict" => "json", "path" => "$.a", "pass_when" => "is zero"})

    assert msg =~ "pass_when"
  end

  test "an exit_code verdict without pass_codes is a load error" do
    assert {:error, msg} = load(%{"cmd" => "x", "verdict" => "exit_code"})
    assert msg =~ "requires a non-empty integer array \"pass_codes\""
  end

  test "an exit_code verdict with non-integer pass_codes is a load error" do
    assert {:error, msg} =
             load(%{"cmd" => "x", "verdict" => "exit_code", "pass_codes" => ["0"]})

    assert msg =~ "must be an array of integers"
  end

  test "non-integer error_codes is a load error" do
    assert {:error, msg} = load(%{"cmd" => "x", "error_codes" => ["2"]})
    assert msg =~ "error_codes"
  end

  test "an unknown evidence_format is a load error" do
    assert {:error, msg} = load(%{"cmd" => "x", "evidence_format" => "yaml"})
    assert msg =~ "unknown evidence_format"
  end

  test "a non-positive timeout_ms is a load error" do
    assert {:error, msg} = load(%{"cmd" => "x", "timeout_ms" => 0})
    assert msg =~ "timeout_ms"
  end

  test "other provider kinds are unaffected by custom_script validation" do
    assert {:ok, _} =
             Loader.from_map(%{
               "id" => "g",
               "predicate" => [
                 %{"id" => "t", "provider" => "test_runner", "cmd" => "go", "args" => ["test"]}
               ]
             })
  end
end

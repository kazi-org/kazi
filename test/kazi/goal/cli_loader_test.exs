defmodule Kazi.Goal.CliLoaderTest do
  @moduledoc """
  T43.7 (UC-055): the loader maps `provider = "cli"` to the `:cli` kind and
  validates its assertions, so a mis-declared cli gate — above all a predicate with
  NO assertions (which could never pass or fail meaningfully) — fails loudly at
  load, not silently at dispatch.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Goal.Loader

  defp load(predicate_toml) do
    Loader.from_map(%{
      "id" => "g",
      "predicate" => [Map.merge(%{"id" => "p", "provider" => "cli"}, predicate_toml)]
    })
  end

  test "a cli predicate with cmd + assertions loads" do
    config = %{
      "cmd" => "kazi",
      "args" => ["version"],
      "assertions" => [%{"target" => "exit_code", "expected" => 0}]
    }

    assert {:ok, %Goal{predicates: [%Predicate{kind: :cli}]}} = load(config)
  end

  test "a cli predicate with NO assertions is a load error" do
    assert {:error, msg} = load(%{"cmd" => "kazi", "args" => ["version"]})
    assert msg =~ "assertions"
  end

  test "an empty assertions list is a load error" do
    assert {:error, msg} = load(%{"cmd" => "kazi", "assertions" => []})
    assert msg =~ "NON-EMPTY"
  end

  test "a missing cmd is a load error" do
    assert {:error, msg} = load(%{"assertions" => [%{"target" => "exit_code", "expected" => 0}]})
    assert msg =~ "cmd"
  end

  test "an unknown assertion target is a load error" do
    config = %{"cmd" => "kazi", "assertions" => [%{"target" => "stdin"}]}
    assert {:error, msg} = load(config)
    assert msg =~ "unknown target"
  end

  test "an exit_code assertion without an integer expected is a load error" do
    config = %{"cmd" => "kazi", "assertions" => [%{"target" => "exit_code", "expected" => "0"}]}
    assert {:error, msg} = load(config)
    assert msg =~ "must be an integer"
  end

  test "a json_path assertion without a path is a load error" do
    config = %{
      "cmd" => "kazi",
      "assertions" => [%{"target" => "stdout", "match" => "json_path", "expected" => 1}]
    }

    assert {:error, msg} = load(config)
    assert msg =~ "path"
  end

  test "a regex assertion whose pattern does not compile is a load error" do
    config = %{
      "cmd" => "kazi",
      "assertions" => [%{"target" => "stdout", "match" => "regex", "expected" => "("}]
    }

    assert {:error, msg} = load(config)
    assert msg =~ "does not compile"
  end

  test "an unknown matcher is a load error" do
    config = %{
      "cmd" => "kazi",
      "assertions" => [%{"target" => "stdout", "match" => "startswith", "expected" => "x"}]
    }

    assert {:error, msg} = load(config)
    assert msg =~ "unknown match"
  end

  # --- T43.8: script / golden / samples --------------------------------------

  test "a cli predicate gated by a script (no top-level assertions) loads" do
    config = %{
      "cmd" => "kazi",
      "script" => [
        %{"args" => ["version"], "assertions" => [%{"target" => "exit_code", "expected" => 0}]},
        %{"args" => ["status"], "assertions" => [%{"target" => "exit_code", "expected" => 0}]}
      ]
    }

    assert {:ok, %Goal{predicates: [%Predicate{kind: :cli}]}} = load(config)
  end

  test "an empty script is a load error" do
    assert {:error, msg} = load(%{"cmd" => "kazi", "script" => []})
    assert msg =~ "NON-EMPTY"
  end

  test "a script step with no assertions is a load error naming the step" do
    config = %{
      "cmd" => "kazi",
      "script" => [%{"args" => ["version"], "assertions" => []}]
    }

    assert {:error, msg} = load(config)
    assert msg =~ "script step 1"
  end

  test "a script step's bad assertion is validated with the same vocabulary" do
    config = %{
      "cmd" => "kazi",
      "script" => [
        %{"args" => ["version"], "assertions" => [%{"target" => "exit_code", "expected" => "0"}]}
      ]
    }

    assert {:error, msg} = load(config)
    assert msg =~ "must be an integer"
  end

  test "a golden assertion without a golden path is a load error" do
    config = %{
      "cmd" => "kazi",
      "assertions" => [%{"target" => "stdout", "match" => "golden"}]
    }

    assert {:error, msg} = load(config)
    assert msg =~ "golden"
  end

  test "a golden assertion with a golden path loads" do
    config = %{
      "cmd" => "kazi",
      "assertions" => [
        %{"target" => "stdout", "match" => "golden", "golden" => "test/fixtures/help.golden"}
      ]
    }

    assert {:ok, %Goal{predicates: [%Predicate{kind: :cli}]}} = load(config)
  end

  test "a non-positive samples is a load error" do
    config = %{
      "cmd" => "kazi",
      "assertions" => [%{"target" => "exit_code", "expected" => 0}],
      "samples" => 0
    }

    assert {:error, msg} = load(config)
    assert msg =~ "positive integer"
  end

  test "a positive samples loads" do
    config = %{
      "cmd" => "kazi",
      "assertions" => [%{"target" => "exit_code", "expected" => 0}],
      "samples" => 3
    }

    assert {:ok, %Goal{predicates: [%Predicate{kind: :cli}]}} = load(config)
  end
end

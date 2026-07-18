defmodule Kazi.Goal.SwiftTestLoaderTest do
  @moduledoc """
  Issue #1406: the loader maps `provider = "swift_test"` to the `:swift_test`
  kind and VALIDATES its `xcresult_path`, so a swift_test predicate with
  nothing to read fails loudly at load, not silently at dispatch.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Goal.Loader

  defp load(predicate_toml) do
    Loader.from_map(%{
      "id" => "g",
      "predicate" => [Map.merge(%{"id" => "p", "provider" => "swift_test"}, predicate_toml)]
    })
  end

  @ok %{"xcresult_path" => "TestResults.xcresult"}

  test "a well-formed swift_test predicate loads" do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :swift_test, config: config}]}} = load(@ok)
    assert config.xcresult_path == "TestResults.xcresult"
  end

  test "swift_test is registered against the real provider module" do
    assert Kazi.Runtime.provider_modules()[:swift_test] == Kazi.Providers.SwiftTest
  end

  test "a missing xcresult_path is a load error" do
    assert {:error, msg} = load(%{})
    assert msg =~ "xcresult_path"
  end

  test "an empty xcresult_path is a load error" do
    assert {:error, msg} = load(%{"xcresult_path" => ""})
    assert msg =~ "xcresult_path"
  end

  test "cmd/args/env/merge_stderr/timeout_ms are accepted config keys" do
    assert {:ok, %Goal{predicates: [%Predicate{config: config}]}} =
             load(%{
               "xcresult_path" => "TestResults.xcresult",
               "cmd" => "xcrun",
               "args" => ["xcresulttool", "get", "test-results", "summary"],
               "env" => %{"DEVELOPER_DIR" => "/Applications/Xcode.app"},
               "merge_stderr" => false,
               "timeout_ms" => 60_000
             })

    assert config.cmd == "xcrun"
    assert config.timeout_ms == 60_000
  end
end

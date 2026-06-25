defmodule Kazi.Predicate.SchemaTest do
  @moduledoc """
  T32.1 (ADR-0040 decision 6): `kazi schema custom_script` self-describes every
  config key the generic command-runner accepts, so an agent can introspect it at
  runtime with no external docs.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kazi.Predicate.Schema

  # Every key the custom_script provider accepts must appear in its schema.
  @expected_keys ~w(cmd args env verdict pass_codes fail_codes path pass_when error_codes
                    evidence_format timeout_ms)

  test "the custom_script schema lists EVERY config key" do
    {:ok, schema} = Schema.fetch("custom_script")
    listed = schema.keys |> Enum.map(& &1.name) |> MapSet.new()

    assert MapSet.equal?(listed, MapSet.new(@expected_keys)),
           "schema keys drifted: #{inspect(listed)}"
  end

  test "every key descriptor is fully documented (name/type/required/description)" do
    {:ok, schema} = Schema.fetch("custom_script")

    for key <- schema.keys do
      assert is_binary(key.name) and key.name != ""
      assert is_binary(key.type) and key.type != ""
      assert is_boolean(key.required)
      assert is_binary(key.description) and key.description != ""
    end
  end

  test "fetch/1 returns :error for an unknown kind" do
    assert Schema.fetch("not_a_provider") == :error
  end

  describe "kazi schema custom_script (CLI)" do
    test "emits the custom_script key schema as JSON and exits 0" do
      out = capture_io(fn -> assert Kazi.CLI.run(["schema", "custom_script"]) == 0 end)

      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["kind"] == "custom_script"
      key_names = payload["keys"] |> Enum.map(& &1["name"]) |> MapSet.new()
      assert MapSet.equal?(key_names, MapSet.new(@expected_keys))
    end

    test "an unknown schema key still reports 'no result schema' (non-zero exit)" do
      out = capture_io(fn -> assert Kazi.CLI.run(["schema", "not-a-thing"]) == 1 end)
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["error"] =~ "no result schema"
      # The error now also lists the available provider schemas.
      assert payload["error"] =~ "custom_script"
    end
  end
end

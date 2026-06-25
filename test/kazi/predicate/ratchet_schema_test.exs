defmodule Kazi.Predicate.RatchetSchemaTest do
  @moduledoc """
  T32.3 (ADR-0041): `kazi schema ratchet` self-describes the ratchet config keys
  (metric/baseline/direction/allowed_regression), so an agent can introspect the
  mode at runtime with no external docs.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kazi.Predicate.Schema

  @expected_keys ~w(metric baseline direction allowed_regression)

  test "the ratchet schema lists every config key" do
    {:ok, schema} = Schema.fetch("ratchet")
    listed = schema.keys |> Enum.map(& &1.name) |> MapSet.new()
    assert MapSet.equal?(listed, MapSet.new(@expected_keys))
  end

  test "ratchet is advertised among the documented provider kinds" do
    assert "ratchet" in Schema.kinds()
  end

  test "every ratchet key descriptor is fully documented" do
    {:ok, schema} = Schema.fetch("ratchet")

    for key <- schema.keys do
      assert is_binary(key.name) and key.name != ""
      assert is_binary(key.type) and key.type != ""
      assert is_boolean(key.required)
      assert is_binary(key.description) and key.description != ""
    end
  end

  test "kazi schema ratchet emits the key schema as JSON and exits 0" do
    out = capture_io(fn -> assert Kazi.CLI.run(["schema", "ratchet"]) == 0 end)
    assert {:ok, payload} = Jason.decode(String.trim(out))
    assert payload["kind"] == "ratchet"
    key_names = payload["keys"] |> Enum.map(& &1["name"]) |> MapSet.new()
    assert MapSet.equal?(key_names, MapSet.new(@expected_keys))
  end
end

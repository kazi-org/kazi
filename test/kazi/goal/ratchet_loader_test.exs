defmodule Kazi.Goal.RatchetLoaderTest do
  @moduledoc """
  T32.3 (ADR-0041): the loader maps `provider = "ratchet"` to the `:ratchet` kind
  and VALIDATES its metric/baseline/direction keys, so a mis-declared ratchet
  fails loudly at load time rather than silently at dispatch.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Goal.Loader

  defp load(predicate_toml) do
    Loader.from_map(%{
      "id" => "g",
      "predicate" => [Map.merge(%{"id" => "p", "provider" => "ratchet"}, predicate_toml)]
    })
  end

  @ok %{
    "metric" => %{"cmd" => "scripts/coverage", "args" => ["--json"], "path" => "$.totals.percent"},
    "baseline" => "stored",
    "direction" => "higher_better",
    "allowed_regression" => 0.0
  }

  test "a well-formed ratchet predicate loads with config carried verbatim" do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :ratchet, config: config}]}} = load(@ok)
    assert config.baseline == "stored"
    assert config.direction == "higher_better"
    assert config.metric["cmd"] == "scripts/coverage"
  end

  test "a numeric baseline loads" do
    assert {:ok, _} = load(%{@ok | "baseline" => 80.0})
  end

  test "a git-ref baseline loads" do
    assert {:ok, _} = load(%{@ok | "baseline" => "main"})
  end

  test "a missing metric table is a load error" do
    assert {:error, msg} = load(Map.delete(@ok, "metric"))
    assert msg =~ "requires a \"metric\" table"
  end

  test "a metric table without a cmd is a load error" do
    assert {:error, msg} = load(%{@ok | "metric" => %{"args" => ["x"]}})
    assert msg =~ "non-empty string \"cmd\""
  end

  test "an unknown direction is a load error" do
    assert {:error, msg} = load(%{@ok | "direction" => "sideways"})
    assert msg =~ "direction"
  end

  test "a missing direction is a load error" do
    assert {:error, msg} = load(Map.delete(@ok, "direction"))
    assert msg =~ "direction"
  end

  test "a missing baseline is a load error" do
    assert {:error, msg} = load(Map.delete(@ok, "baseline"))
    assert msg =~ "requires a \"baseline\""
  end

  test "a non-numeric allowed_regression is a load error" do
    assert {:error, msg} = load(%{@ok | "allowed_regression" => "lots"})
    assert msg =~ "allowed_regression"
  end

  test "allowed_regression is optional (defaults applied at dispatch)" do
    assert {:ok, _} = load(Map.delete(@ok, "allowed_regression"))
  end
end

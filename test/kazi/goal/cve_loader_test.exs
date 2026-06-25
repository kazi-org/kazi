defmodule Kazi.Goal.CveLoaderTest do
  @moduledoc """
  T32.8 (ADR-0043): the loader maps `provider = "cve"` to the `:cve` kind and
  validates its tool + (for the manifest tier) count_path, so a mis-declared cve
  gate fails loudly at load. govulncheck (tier 1) needs no count_path — it parses
  its reachability stream.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Goal.Loader

  defp load(predicate_toml) do
    Loader.from_map(%{
      "id" => "g",
      "predicate" => [Map.merge(%{"id" => "p", "provider" => "cve"}, predicate_toml)]
    })
  end

  test "a govulncheck (tier-1) predicate loads with no count_path" do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :cve}]}} = load(%{"tool" => "govulncheck"})
  end

  test "cve defaults to govulncheck (no tool declared) and loads" do
    assert {:ok, _} = load(%{})
  end

  test "a manifest tool loads with a count_path" do
    config = %{"tool" => "npm_audit", "count_path" => "$.metadata.vulnerabilities.total"}
    assert {:ok, _} = load(config)
  end

  test "a manifest tool WITHOUT a count_path is a load error" do
    assert {:error, msg} = load(%{"tool" => "trivy"})
    assert msg =~ "count_path"
  end

  test "an unknown tool is a load error" do
    assert {:error, msg} = load(%{"tool" => "snyk"})
    assert msg =~ "unknown tool"
  end
end

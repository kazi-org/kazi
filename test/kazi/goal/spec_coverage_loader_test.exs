defmodule Kazi.Goal.SpecCoverageLoaderTest do
  @moduledoc """
  The loader admits `spec_coverage` as a known provider and its config keys load.
  This matters for the RELEASE binary: `:spec_coverage`, `:features`, `:allow_list`,
  and `:source_dirs` are compile-time atom literals in `Kazi.Providers.SpecCoverage`,
  so `ensure_provider_loaded` interns them before the loader's
  `String.to_existing_atom/1` check — the atom-interning landmine (devlog 2026-07-15)
  where a goal loads under `mix` but is rejected as an "unknown config key" in the
  release. A test that the goal LOADS is the guard.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}
  alias Kazi.Goal.Loader

  defp load(config) do
    Loader.from_map(%{
      "id" => "g",
      "predicate" => [Map.merge(%{"id" => "p", "provider" => "spec_coverage"}, config)]
    })
  end

  test "spec_coverage is a known provider — a minimal goal loads" do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :spec_coverage}]}} = load(%{})
  end

  test "every config key (features/allow_list/source_dirs) is admitted, not rejected as unknown" do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :spec_coverage, config: config}]}} =
             load(%{
               "features" => "docs/specs/**/*.feature",
               "allow_list" => ["Kazi.Internal.*"],
               "source_dirs" => ["lib"]
             })

    assert config[:features] == "docs/specs/**/*.feature"
    assert config[:allow_list] == ["Kazi.Internal.*"]
    assert config[:source_dirs] == ["lib"]
  end
end

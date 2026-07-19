defmodule Kazi.SpecsExampleTest do
  @moduledoc """
  T40.1 (ADR-0050): the worked behavior spec `docs/specs/example.feature` must
  parse cleanly through `Kazi.Reconcile.GherkinImporter` — the tier dogfoods
  itself from day one, and this test fails the moment the example drifts into
  something the importer cannot turn into predicates.
  """
  use ExUnit.Case, async: true

  alias Kazi.Reconcile.GherkinImporter

  @example Path.join([File.cwd!(), "docs", "specs", "example.feature"])

  test "docs/specs/example.feature exists and imports to a valid goal" do
    assert File.exists?(@example), "the worked example behavior spec is missing"

    text = File.read!(@example)

    assert {:ok, map} = GherkinImporter.import_map(text)
    assert map["mode"] == "create"
    # Every Scenario in the example becomes one acceptance predicate.
    assert length(map["predicate"]) >= 4
    assert Enum.all?(map["predicate"], &(&1["provider"] == "custom_script"))

    # It round-trips through the same validated loader `kazi apply` uses.
    assert {:ok, _goal} = Kazi.Goal.Loader.from_map(map)
  end
end

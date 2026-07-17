defmodule Kazi.Reconcile.GherkinImporterLoweringTest do
  # T49.11 (ADR-0054 d3, ADR-0064): `import_map/2`'s opt-in `:lower` mode.
  # `:test_runner` (the default) is byte-identical to a pre-lowering import;
  # `:scenario` lowers a Scenario TAGGED @interface:web/@interface:cli to a
  # runtime `scenario` predicate (browser/cli surface), while an untagged
  # Scenario — and one tagged with any other interface — stays `test_runner`.
  # Lowering never FORCES a Scenario into the scenario-provider shape.
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Reconcile.GherkinImporter

  # A mixed fixture: @interface:web + @interface:cli (both lowerable),
  # @interface:api (not lowerable), and an untagged-interface Scenario.
  @fixture Path.expand("../../fixtures/reconcile/product_catalog.feature", __DIR__)

  defp fixture_text, do: File.read!(@fixture)

  defp import!(opts) do
    {:ok, map} = GherkinImporter.import_map(fixture_text(), opts)
    Map.new(map["predicate"], &{&1["id"], &1})
  end

  @web_id "storefront__a-shopper-checks-out-a-basket"
  @cli_id "operator-tooling__an-operator-lists-releases"
  @api_id "storefront__a-partner-queries-order-status"
  @untagged_id "storefront__a-shopper-browses-the-catalogue"

  describe ":scenario lowering derives scenario-kind predicates on the right surface" do
    setup do
      {:ok, by_id: import!(lower: :scenario, spec_paths: [@fixture])}
    end

    test "@interface:web lowers to a scenario predicate on the browser surface", %{by_id: by_id} do
      web = by_id[@web_id]

      assert web["provider"] == "scenario"
      assert web["surface"] == "browser"
      assert web["scenario"] == "A shopper checks out a basket"
      assert web["spec"] == @fixture
    end

    test "@interface:cli lowers to a scenario predicate on the cli surface", %{by_id: by_id} do
      cli = by_id[@cli_id]

      assert cli["provider"] == "scenario"
      assert cli["surface"] == "cli"
      assert cli["scenario"] == "An operator lists releases"
      assert cli["spec"] == @fixture
    end

    test "an untagged Scenario stays test_runner even under :scenario (never forced)", %{
      by_id: by_id
    } do
      untagged = by_id[@untagged_id]

      assert untagged["provider"] == "custom_script"
      refute Map.has_key?(untagged, "surface")
    end

    test "a Scenario tagged with a non-lowerable interface stays test_runner", %{by_id: by_id} do
      # @interface:api is recognized metadata but has no scenario-provider surface,
      # so lowering must NOT force it into the scenario shape.
      api = by_id[@api_id]

      assert api["provider"] == "custom_script"
      assert api["interface"] == "api"
      refute Map.has_key?(api, "surface")
    end

    test "the lowered goal loads with :scenario-kind predicates on the tagged Scenarios" do
      {:ok, %Goal{} = goal} =
        GherkinImporter.import_goal(fixture_text(), lower: :scenario, spec_paths: [@fixture])

      by_id = Map.new(goal.predicates, &{to_string(&1.id), &1})

      assert by_id[@web_id].kind == :scenario
      assert by_id[@cli_id].kind == :scenario
      assert by_id[@api_id].kind == :custom_script
      assert by_id[@untagged_id].kind == :custom_script
    end
  end

  describe "default lowering is byte-identical to a pre-lowering import (ADR-0054 compat)" do
    test "the fixture WITHOUT the flag matches an explicit :test_runner import" do
      {:ok, without_flag} = GherkinImporter.import_map(fixture_text())
      {:ok, explicit_default} = GherkinImporter.import_map(fixture_text(), lower: :test_runner)

      assert without_flag == explicit_default
    end

    test "no predicate under the default carries a scenario provider or surface" do
      by_id = import!(lower: :test_runner)

      refute Enum.any?(Map.values(by_id), &(&1["provider"] == "scenario"))
      refute Enum.any?(Map.values(by_id), &Map.has_key?(&1, "surface"))
    end

    test "derived ids and Feature grouping are identical across lowering modes" do
      {:ok, default_map} = GherkinImporter.import_map(fixture_text(), spec_paths: [@fixture])

      {:ok, lowered_map} =
        GherkinImporter.import_map(fixture_text(), lower: :scenario, spec_paths: [@fixture])

      ids = &Enum.map(&1["predicate"], fn p -> p["id"] end)
      groups = & &1["group"]

      assert ids.(default_map) == ids.(lowered_map)
      assert groups.(default_map) == groups.(lowered_map)
    end
  end

  describe "an unknown lower mode is a clear error, never a silent default" do
    test "import_map rejects an unrecognized :lower value" do
      assert {:error, message} = GherkinImporter.import_map(fixture_text(), lower: :bogus)
      assert message =~ "unknown lower mode"
    end
  end
end

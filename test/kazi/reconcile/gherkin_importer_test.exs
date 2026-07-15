defmodule Kazi.Reconcile.GherkinImporterTest do
  # T13.2: gherkin .feature -> grouped custom_script acceptance predicates
  # (ADR-0021 §1, ADR-0020 groups; migrated off the deprecated test_runner to
  # custom_script/exit_zero scaffolds, ADR-0040/E40). Hermetic — reads a
  # committed fixture .feature under test/fixtures/reconcile and in-line strings;
  # no network, no clock, no gherkin dependency.
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader
  alias Kazi.Reconcile.GherkinImporter

  @fixture Path.expand("../../fixtures/reconcile/checkout.feature", __DIR__)

  defp fixture_text, do: File.read!(@fixture)

  describe "import_map/2 — scenarios become grouped custom_script predicates" do
    test "one custom_script acceptance predicate per Scenario with feature+scenario+steps config" do
      {:ok, map} = GherkinImporter.import_map(fixture_text())

      # 5 scenarios: 2 under Checkout, 2 across the two Sign Up features, 1 under
      # the blank feature.
      assert length(map["predicate"]) == 5

      Enum.each(map["predicate"], fn p ->
        assert p["provider"] == "custom_script"
        # A SCAFFOLD (ADR-0040/E40): verdict=exit_zero with a placeholder cmd/args
        # that loads but exits non-zero — honestly RED until a human wires the
        # real check.
        assert p["verdict"] == "exit_zero"
        assert is_binary(p["cmd"]) and p["cmd"] != ""
        assert is_list(p["args"])
        assert p["acceptance"] == true
        assert is_binary(p["feature"])
        assert is_binary(p["scenario"])
        assert is_list(p["steps"])
        assert is_binary(p["group"])
        assert is_binary(p["description"])
      end)
    end

    test "the goal is in create mode (predicates are acceptance criteria)" do
      {:ok, map} = GherkinImporter.import_map(fixture_text())
      assert map["mode"] == "create"
    end

    test "scenario name and steps are captured from the feature" do
      {:ok, map} = GherkinImporter.import_map(fixture_text())
      by_id = Map.new(map["predicate"], &{&1["id"], &1})

      checkout = by_id["checkout__a-shopper-checks-out-a-basket"]
      assert checkout["scenario"] == "A shopper checks out a basket"
      assert checkout["feature"] == "Checkout"

      assert checkout["steps"] == [
               "Given a basket with two items",
               "When the shopper pays with a valid card",
               "Then the order is confirmed",
               "And a receipt is emailed"
             ]
    end

    test "Scenario Outline is treated as a single scenario (Examples rows ignored)" do
      {:ok, map} = GherkinImporter.import_map(fixture_text())
      by_id = Map.new(map["predicate"], &{&1["id"], &1})

      outline = by_id["checkout__payment-is-declined-for-a-bad-card"]
      assert outline["scenario"] == "Payment is declined for a bad card"
      # The Examples table rows are not steps.
      assert outline["steps"] == [
               "Given a basket with one item",
               "When the shopper pays with a <card>",
               "Then the payment is declined"
             ]
    end

    test "Background steps are not attached to a scenario" do
      {:ok, map} = GherkinImporter.import_map(fixture_text())
      by_id = Map.new(map["predicate"], &{&1["id"], &1})

      checkout = by_id["checkout__a-shopper-checks-out-a-basket"]
      # "Given the store catalogue is loaded" lives under Background:, not the
      # scenario — it must not leak into the scenario's steps.
      refute "Given the store catalogue is loaded" in checkout["steps"]
    end

    test "the description captures the scenario name and its steps" do
      {:ok, map} = GherkinImporter.import_map(fixture_text())
      by_id = Map.new(map["predicate"], &{&1["id"], &1})

      desc = by_id["sign-up__a-new-user-signs-up"]["description"]
      assert desc =~ "A new user signs up"
      assert desc =~ "Given a visitor on the home page"
    end
  end

  describe "import_map/2 — grouping by Feature into declared [[group]] entries" do
    test "each Feature becomes a declared group (id = normalized feature name)" do
      {:ok, map} = GherkinImporter.import_map(fixture_text())
      group_ids = map["group"] |> Enum.map(& &1["id"]) |> Enum.sort()

      # Features: "Checkout", "Sign Up", "sign-up" (-> one group), and a blank
      # feature (-> "ungrouped").
      assert group_ids == ["checkout", "sign-up", "ungrouped"]
    end

    test "feature spelling variants collapse to one group (normalize_id), not two" do
      {:ok, map} = GherkinImporter.import_map(fixture_text())
      ids = Enum.map(map["group"], & &1["id"])
      # "Sign Up" and "sign-up" both normalize to "sign-up" — the tree must not
      # fragment (ADR-0020).
      assert Enum.count(ids, &(&1 == "sign-up")) == 1
    end

    test "a scenario under a blank feature falls into the default 'ungrouped' group" do
      {:ok, map} = GherkinImporter.import_map(fixture_text())
      by_id = Map.new(map["predicate"], &{&1["id"], &1})
      assert by_id["ungrouped__the-health-endpoint-responds"]["group"] == "ungrouped"
      assert Enum.any?(map["group"], &(&1["id"] == "ungrouped"))
    end

    test "each predicate's group references a declared group id" do
      {:ok, map} = GherkinImporter.import_map(fixture_text())
      declared = MapSet.new(map["group"], & &1["id"])

      Enum.each(map["predicate"], fn p ->
        assert MapSet.member?(declared, p["group"]),
               "predicate #{p["id"]} references undeclared group #{inspect(p["group"])}"
      end)
    end
  end

  describe "round-trips through Kazi.Goal.Loader.from_map/1" do
    test "the emitted map loads into a create-mode goal with grouped acceptance predicates" do
      {:ok, map} = GherkinImporter.import_map(fixture_text())
      assert {:ok, %Goal{} = goal} = Loader.from_map(map)

      assert goal.mode == :create
      assert length(goal.predicates) == 5
      assert Enum.all?(goal.predicates, &(&1.kind == :custom_script))
      assert Enum.all?(goal.predicates, & &1.acceptance?)

      # Groups round-trip with normalized ids.
      group_ids = goal.groups |> Enum.map(& &1.id) |> Enum.sort()
      assert group_ids == ["checkout", "sign-up", "ungrouped"]

      # The group reference lands on Predicate.group (a declared id the loader
      # validates, T12.2); feature/scenario/steps fall through to config.
      acceptance = Kazi.Goal.acceptance_predicates(goal)
      assert length(acceptance) == 5

      signup = Enum.find(acceptance, &(&1.id == "sign-up__a-new-user-signs-up"))
      assert signup.group == "sign-up"
      assert signup.config[:feature] == "Sign Up"
      assert signup.config[:scenario] == "A new user signs up"
      assert signup.config[:steps] |> hd() == "Given a visitor on the home page"
    end

    test "import_goal/2 is the loader convenience wrapper" do
      assert {:ok, %Goal{mode: :create}} = GherkinImporter.import_goal(fixture_text())
    end
  end

  describe "determinism and re-import (upsert)" do
    test "the same features yield a byte-identical goal map" do
      {:ok, a} = GherkinImporter.import_map(fixture_text())
      {:ok, b} = GherkinImporter.import_map(fixture_text())
      assert a == b
    end

    test "scenarios are emitted in document order, grouped by feature" do
      feature = """
      Feature: Alpha
        Scenario: first
          Then ok
        Scenario: second
          Then ok

      Feature: Beta
        Scenario: third
          Then ok
      """

      {:ok, map} = GherkinImporter.import_map(feature)

      assert Enum.map(map["predicate"], & &1["id"]) == [
               "alpha__first",
               "alpha__second",
               "beta__third"
             ]
    end

    test "re-import produces stable ids and no duplicates (upsert)" do
      {:ok, a} = GherkinImporter.import_map(fixture_text())
      {:ok, b} = GherkinImporter.import_map(fixture_text())

      ids_a = Enum.map(a["predicate"], & &1["id"])
      ids_b = Enum.map(b["predicate"], & &1["id"])

      assert ids_a == ids_b

      assert ids_a == Enum.uniq(ids_a),
             "predicate ids must be unique (no duplicates on re-import)"
    end

    test "two scenarios deriving the same id are de-duplicated, keeping the first" do
      feature = """
      Feature: Dup
        Scenario: same name
          Then a
        Scenario: same name
          Then b
      """

      {:ok, map} = GherkinImporter.import_map(feature)
      assert length(map["predicate"]) == 1
      assert hd(map["predicate"])["steps"] == ["Then a"]
    end
  end

  describe "options and inputs" do
    test "accepts a single string and a list of strings" do
      one = "Feature: A\n  Scenario: s1\n    Then ok\n"
      two = "Feature: B\n  Scenario: s2\n    Then ok\n"

      {:ok, from_list} = GherkinImporter.import_map([one, two])
      assert Enum.map(from_list["predicate"], & &1["id"]) == ["a__s1", "b__s2"]

      {:ok, from_string} = GherkinImporter.import_map(one)
      assert Enum.map(from_string["predicate"], & &1["id"]) == ["a__s1"]
    end

    test ":id and :name override the derived defaults" do
      {:ok, map} =
        GherkinImporter.import_map(fixture_text(), id: "checkout-suite", name: "My Suite")

      assert map["id"] == "checkout-suite"
      assert map["name"] == "My Suite"
    end

    test "the goal id defaults to gherkin-import and the name to the first feature" do
      {:ok, map} = GherkinImporter.import_map(fixture_text())
      assert map["id"] == "gherkin-import"
      assert map["name"] == "Checkout"
    end

    test "input with no Scenario is a clear tagged error, not a crash" do
      assert {:error, reason} = GherkinImporter.import_map("Feature: Empty\n  # no scenarios\n")
      assert reason =~ "no Scenario"
    end

    test "empty input is a clear tagged error" do
      assert {:error, reason} = GherkinImporter.import_map("")
      assert reason =~ "no Scenario"
    end

    test "a non-string, non-list source is a clear tagged error" do
      assert {:error, reason} = GherkinImporter.import_map(%{not: "gherkin"})
      assert reason =~ "string or a list"
    end
  end
end

defmodule Kazi.Reconcile.GherkinImporterTagsTest do
  # T41.1 (ADR-0054): the importer reads Cucumber `@tag` lines and recognizes
  # kazi's own vocabulary — @role:<role>, @priority:P0..P3, and
  # @interface:web|api|cli|sdk|grpc|background|ws — carrying role/priority onto
  # the derived predicate's config as self-describing metadata (mirroring how
  # `steps` already do), and letting @interface select the provider kind.
  #
  # Backward-compat (untagged output is byte-identical) is pinned separately by
  # gherkin_importer_backcompat_test.exs against goldens generated from the
  # pre-T41.1 importer.
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Reconcile.GherkinImporter

  @fixture Path.expand("../../fixtures/reconcile/product_catalog.feature", __DIR__)
  @base_url "https://staging.example.com"

  defp fixture_text, do: File.read!(@fixture)

  defp import!(opts \\ []) do
    {:ok, map} = GherkinImporter.import_map(fixture_text(), opts)
    Map.new(map["predicate"], &{&1["id"], &1})
  end

  describe "kazi's tag vocabulary lands on the predicate as metadata" do
    test "@role: and @priority: are carried into config" do
      by_id = import!()
      checkout = by_id["storefront__a-shopper-checks-out-a-basket"]

      assert checkout["role"] == "shopper"
      assert checkout["priority"] == "P0"
    end

    test "a Feature-level tag is inherited by its Scenarios (real Cucumber semantics)" do
      by_id = import!()

      # @role:shopper is declared on `Feature: Storefront`, not on the Scenario.
      assert by_id["storefront__a-shopper-browses-the-catalogue"]["role"] == "shopper"
    end

    test "a Scenario-level tag overrides the Feature-level one" do
      by_id = import!()

      # The Feature declares @role:shopper; this Scenario declares @role:partner.
      assert by_id["storefront__a-partner-queries-order-status"]["role"] == "partner"
    end

    test "@interface is recorded even when it does not change the provider kind" do
      by_id = import!()
      cli = by_id["operator-tooling__an-operator-lists-releases"]

      assert cli["interface"] == "cli"
      assert cli["role"] == "operator"
      assert cli["priority"] == "P2"
      # No dedicated provider for a cli interface — the scaffold stands.
      assert cli["provider"] == "custom_script"
    end

    test "role/priority/interface round-trip through the loader onto config" do
      {:ok, goal} = GherkinImporter.import_goal(fixture_text(), base_url: @base_url)

      checkout =
        Enum.find(goal.predicates, &(&1.id == "storefront__a-shopper-checks-out-a-basket"))

      assert checkout.config[:role] == "shopper"
      assert checkout.config[:priority] == "P0"
      assert checkout.config[:interface] == "web"
    end
  end

  describe "@interface selects the provider kind (grounded by :base_url)" do
    test "@interface:web derives a browser predicate" do
      by_id = import!(base_url: @base_url)
      checkout = by_id["storefront__a-shopper-checks-out-a-basket"]

      assert checkout["provider"] == "browser"
      assert checkout["url"] == @base_url
    end

    test "@interface:api derives an http_probe predicate" do
      by_id = import!(base_url: @base_url)
      partner = by_id["storefront__a-partner-queries-order-status"]

      assert partner["provider"] == "http_probe"
      assert partner["url"] == @base_url
    end

    test "a derived live predicate is honestly RED, never a vacuous pass" do
      # A .feature says WHAT must hold, never HOW to check it. A browser
      # predicate with no assertions PASSES on any page that renders, and an
      # http_probe with no expectation PASSES on any completed request — so a
      # bare derived probe would report every use case green while verifying
      # nothing (and, when a whole goal went green, Kazi.Runtime's t0 guard
      # would reject it as :vacuous_goal). Both carry a placeholder expectation
      # that cannot hold until a human replaces it — the same honestly-RED
      # scaffold posture the custom_script cmd/args placeholder already takes.
      by_id = import!(base_url: @base_url)

      assert [%{"contains" => todo}] =
               by_id["storefront__a-shopper-checks-out-a-basket"]["assertions"]

      assert todo =~ "replace"

      assert by_id["storefront__a-partner-queries-order-status"]["expect_body"] =~ "replace"
    end

    test "derived live predicates load (they satisfy the loader's required url)" do
      # ADR-0058/T48.1: an http_probe or browser predicate with no `url` is a
      # LOAD error — a url-less live predicate can only ever :error, which burned
      # 40 iterations in production before the guard existed.
      {:ok, %Goal{} = goal} = GherkinImporter.import_goal(fixture_text(), base_url: @base_url)

      kinds = goal.predicates |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()
      assert kinds == [:browser, :custom_script, :http_probe]
    end

    test "without :base_url a live interface falls back to the custom_script scaffold" do
      # kazi never invents a url (ADR-0013 §3: live predicates are scaffolded,
      # never guessed — cf. Kazi.Adopt.Writer.live_predicate_scaffold/0). With no
      # caller-supplied base url there is nothing honest to probe, so the tag
      # only contributes metadata and the scaffold stands. It still LOADS, where
      # a url-less browser predicate would not.
      by_id = import!()
      checkout = by_id["storefront__a-shopper-checks-out-a-basket"]

      assert checkout["provider"] == "custom_script"
      assert checkout["interface"] == "web"
      refute Map.has_key?(checkout, "url")

      assert {:ok, %Goal{}} = GherkinImporter.import_goal(fixture_text())
    end
  end

  describe "unrecognized and malformed tags are ignored, never an error" do
    test "a house tag outside kazi's vocabulary is ignored" do
      # @product / @owner:growth / @wip are a team's own tags.
      by_id = import!()
      browse = by_id["storefront__a-shopper-browses-the-catalogue"]

      refute Map.has_key?(browse, "wip")
      refute Map.has_key?(browse, "owner")
      refute Map.has_key?(browse, "product")
    end

    test "a malformed @priority value is ignored rather than recorded or raised" do
      by_id = import!()
      # @priority:P9 is not P0..P3.
      refute Map.has_key?(by_id["storefront__a-shopper-browses-the-catalogue"], "priority")
    end

    test "an unknown @interface value does not select a provider" do
      feature = """
      @interface:telepathy
      Feature: Odd
        Scenario: s
          Then ok
      """

      {:ok, map} = GherkinImporter.import_map(feature, base_url: @base_url)
      [pred] = map["predicate"]

      assert pred["provider"] == "custom_script"
      refute Map.has_key?(pred, "interface")
    end

    test "a tag line with several tags is split, and a bare @tag is ignored" do
      feature = """
      Feature: Multi
        @smoke @role:admin @nightly @priority:P3
        Scenario: s
          Then ok
      """

      {:ok, map} = GherkinImporter.import_map(feature)
      [pred] = map["predicate"]

      assert pred["role"] == "admin"
      assert pred["priority"] == "P3"
    end
  end

  describe "determinism" do
    test "a tagged spec imports identically twice" do
      {:ok, a} = GherkinImporter.import_map(fixture_text(), base_url: @base_url)
      {:ok, b} = GherkinImporter.import_map(fixture_text(), base_url: @base_url)
      assert a == b
    end
  end

  describe "release-load safety: tag metadata keys are interned by the loader" do
    # The importer's doc-metadata keys are consumed by NO provider, so the
    # release binary does not otherwise intern their atoms and the loader's
    # atom-existence guard rejects them as "unknown config key" — a goal that
    # loads fine under `mix` (where the fuller module set interns them) fails on
    # the real binary. See docs/devlog.md 2026-07-15 and the sibling test in
    # gherkin_importer_test.exs. This pins the TAGGED key set against
    # Kazi.Goal.Loader's @gherkin_doc_keys.
    test "a tagged import emits exactly the doc-metadata keys the loader interns" do
      {:ok, map} =
        GherkinImporter.import_map(
          "@role:admin @priority:P0 @interface:cli\nFeature: F\n  Scenario: S\n    Then ok\n"
        )

      [pred] = map["predicate"]

      reserved = ~w(id provider description guard acceptance held_out group)
      runner = ~w(verdict cmd args)
      doc_keys = (Map.keys(pred) -- reserved) -- runner

      assert Enum.sort(doc_keys) == ~w(feature interface priority role scenario steps),
             "the importer's doc-metadata keys must match Kazi.Goal.Loader's " <>
               "@gherkin_doc_keys -- a new key here needs interning there, or a " <>
               "spec-imported goal fails to load in the release binary"
    end
  end
end

defmodule Kazi.Reconcile.SpecCoverageTest do
  # Hermetic: hand-built surfaces + fixture `.feature` text. No network, no clock.
  use ExUnit.Case, async: true

  alias Kazi.Predicate
  alias Kazi.Reconcile.{Coverage, GherkinImporter, SpecCoverage, SurfaceElement, SurfaceScanner}

  doctest SpecCoverage

  @surface_fixture Path.expand("../../../test/fixtures/surface", __DIR__)
  @full_feature Path.expand(
                  "../../../test/fixtures/reconcile/spec_coverage_full.feature",
                  __DIR__
                )

  defp el(kind, id, path, line),
    do: SurfaceElement.new(kind, id, path, line)

  describe "an undocumented endpoint fails the meta-predicate and is named" do
    test "an endpoint with no covering Scenario is flagged, the documented one is covered" do
      surface = [
        el(:http_route, "GET /orders", "lib/web.ex", 10),
        el(:http_route, "GET /admin/secret", "lib/web.ex", 20)
      ]

      scenarios = [
        %{
          feature: "Orders",
          scenario: "A shopper lists orders",
          steps: ["When the client sends GET /orders", "Then it sees a list"],
          tags: []
        }
      ]

      result = SpecCoverage.check(surface, scenarios)

      assert result.status == :fail
      assert SpecCoverage.Result.uncovered_identifiers(result) == ["GET /admin/secret"]
      assert Enum.map(result.covered, & &1.identifier) == ["GET /orders"]

      # The failure MESSAGE names the specific missing surface, not just a count.
      message = SpecCoverage.Result.failure_message(result)
      assert message =~ "GET /admin/secret"
      refute message =~ "GET /orders"
    end

    test "every element is named when there are no Scenarios at all" do
      surface = [
        el(:http_route, "GET /a", "lib/web.ex", 1),
        el(:exported_function, "App.Mod.run/1", "lib/mod.ex", 3)
      ]

      result = SpecCoverage.check(surface, [])

      assert result.status == :fail

      # Sorted by SurfaceElement.sort_key/1 — :exported_function before :http_route.
      assert SpecCoverage.Result.uncovered_identifiers(result) ==
               ["App.Mod.run/1", "GET /a"]
    end
  end

  describe "a fully-Scenario-covered fixture passes" do
    test "the shared surface fixture, documented by a real .feature file, passes" do
      surface = SurfaceScanner.scan(@surface_fixture)
      refute surface == []

      scenarios = GherkinImporter.scenarios(File.read!(@full_feature))
      result = SpecCoverage.check(surface, scenarios)

      assert result.status == :pass
      assert result.uncovered == []
      assert SpecCoverage.Result.failure_message(result) == nil

      # Every scanned element ends up in `covered` (none dropped, none uncovered).
      expected_ids = surface |> Enum.map(& &1.identifier) |> Enum.sort()
      assert result.covered |> Enum.map(& &1.identifier) |> Enum.sort() == expected_ids
    end

    test "check_features/3 parses the .feature text itself (same verdict)" do
      surface = SurfaceScanner.scan(@surface_fixture)

      result = SpecCoverage.check_features(surface, File.read!(@full_feature))

      assert result.status == :pass
    end
  end

  describe "reference-like token discipline" do
    test "a plain English word never spuriously covers a short identifier" do
      # "Get" appears as an English word; it must NOT cover the `GET /x` route,
      # because only reference-like words (containing `/` or `.`) become tokens.
      surface = [el(:http_route, "GET /x", "lib/web.ex", 1)]

      scenarios = [
        %{feature: "F", scenario: "The user can Get things done", steps: [], tags: []}
      ]

      assert SpecCoverage.check(surface, scenarios).status == :fail
    end

    test "a backtick-wrapped, punctuation-trailed reference still covers" do
      surface = [el(:exported_function, "Surface.Calc.add/2", "lib/calc.ex", 5)]

      scenarios = [
        %{feature: "F", scenario: "It calls `Surface.Calc.add`.", steps: [], tags: []}
      ]

      assert SpecCoverage.check(surface, scenarios).status == :pass
    end
  end

  describe "allow-list and totality" do
    test "an allow-listed element is covered without a Scenario and reported as allowed" do
      surface = [
        el(:exported_function, "Kazi.Internal.Debug.dump/1", "lib/internal.ex", 2),
        el(:http_route, "GET /public", "lib/web.ex", 3)
      ]

      scenarios = [
        %{feature: "F", scenario: "Uses GET /public", steps: [], tags: []}
      ]

      result = SpecCoverage.check(surface, scenarios, allow_list: ["Kazi.Internal.*"])

      assert result.status == :pass
      assert Enum.map(result.allowed, & &1.identifier) == ["Kazi.Internal.Debug.dump/1"]
      assert Enum.map(result.covered, & &1.identifier) == ["GET /public"]
    end

    test "an empty surface passes vacuously" do
      assert SpecCoverage.check([], []).status == :pass
    end

    test "malformed scenario maps are tolerated, never raise" do
      surface = [el(:http_route, "GET /x", "lib/web.ex", 1)]

      # A map missing :scenario / with a non-list :steps must not crash the check.
      scenarios = [%{tags: []}, %{scenario: 123, steps: nil}]

      assert SpecCoverage.check(surface, scenarios).status == :fail
    end
  end

  describe "independent of T13.5 dead-code-vs-predicates over the SAME repo" do
    test "predicate coverage and Scenario coverage give independent verdicts, no interference" do
      surface = SurfaceScanner.scan(@surface_fixture)
      refute surface == []

      # A predicate set that OWNS every element (dead-code check passes)...
      predicates =
        Enum.map(surface, fn e ->
          Predicate.new(:"p_#{:erlang.phash2(e.identifier)}", :tests,
            description: "covers #{e.identifier}"
          )
        end)

      # ...but NO Scenarios (manifest-coverage fails). Both run over the same surface.
      dead_code = Coverage.check(surface, predicates)
      manifest = SpecCoverage.check(surface, [])

      assert dead_code.status == :pass
      assert manifest.status == :fail

      # And the mirror: full Scenario coverage, empty predicate set — verdicts flip,
      # proving neither check reads or mutates the other's inputs.
      scenarios = GherkinImporter.scenarios(File.read!(@full_feature))

      assert Coverage.check(surface, []).status == :fail
      assert SpecCoverage.check(surface, scenarios).status == :pass
    end
  end
end

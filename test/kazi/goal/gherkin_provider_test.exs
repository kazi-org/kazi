defmodule Kazi.Goal.GherkinProviderTest do
  @moduledoc """
  T62.1 (ADR-0071): a `provider = "gherkin"` predicate expands AT GOAL-LOAD into
  one real `:gherkin` sub-predicate per Scenario (per Examples row for a Scenario
  Outline), grouped under one synthesized `[[group]]` per Feature — preserving
  kazi's one-`[[predicate]]`-to-one-verdict invariant while giving `kazi status`
  per-scenario granularity. Load-time expansion ONLY; verdict ingestion is T62.2,
  so the provider evaluates to honest `:unknown` (ADR-0046).
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal.Loader
  alias Kazi.{Predicate, PredicateResult}

  # Writes a .feature file to a unique tmp path and returns its ABSOLUTE path, so
  # the goal references it without any CWD manipulation (keeps the suite async).
  defp feature_file(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "kazi-gherkin-#{System.unique_integer([:positive])}.feature"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp goal(predicate) do
    %{
      "id" => "g",
      "name" => "g",
      "predicate" => [predicate]
    }
  end

  describe "load-time expansion" do
    test "a Feature expands to one sub-predicate per Scenario, grouped under the Feature" do
      path =
        feature_file("""
        Feature: Storage Store
          Scenario: A record is written
            Given an empty store
            When a record is written
            Then it can be read back

          Scenario: A record is deleted
            Given a store with a record
            When the record is deleted
            Then reading it returns nothing
        """)

      assert {:ok, goal} =
               Loader.from_map(
                 goal(%{
                   "provider" => "gherkin",
                   "feature" => path,
                   "runner_cmd" => "bash",
                   "runner_args" => ["scripts/storage-contract.sh"]
                 })
               )

      assert length(goal.predicates) == 2
      assert Enum.all?(goal.predicates, &(&1.kind == :gherkin))

      assert Enum.map(goal.predicates, & &1.id) == [
               "storage-store__a-record-is-written",
               "storage-store__a-record-is-deleted"
             ]

      # Grouped under one synthesized [[group]] per Feature (normalized id).
      assert Enum.all?(goal.predicates, &(&1.group == "storage-store"))
      assert Enum.any?(goal.groups, &(&1.id == "storage-store"))

      # The shared runner spec rides on every sub-predicate's config.
      [first | _] = goal.predicates
      assert first.config[:feature] == path
      assert first.config[:scenario] == "A record is written"
      assert first.config[:verdict_format] == "cucumber_json"
      assert first.config[:runner_cmd] == "bash"
      assert first.config[:runner_args] == ["scripts/storage-contract.sh"]

      assert first.config[:steps] == [
               "Given an empty store",
               "When a record is written",
               "Then it can be read back"
             ]
    end

    test "a Scenario Outline expands to one sub-predicate PER Examples row" do
      path =
        feature_file("""
        Feature: Checkout
          Scenario Outline: Payment declined for <card>
            Given a basket
            When paying with a <card> card
            Then the payment is declined

            Examples:
              | card    |
              | expired |
              | stolen  |
        """)

      assert {:ok, goal} =
               Loader.from_map(
                 goal(%{
                   "provider" => "gherkin",
                   "feature" => path,
                   "runner_cmd" => "bash",
                   "runner_args" => ["run.sh"]
                 })
               )

      assert length(goal.predicates) == 2

      assert Enum.map(goal.predicates, & &1.id) == [
               "checkout__payment-declined-for-card__expired",
               "checkout__payment-declined-for-card__stolen"
             ]

      # Row-level status: each row carries its own row_key + substituted steps.
      [expired, stolen] = goal.predicates
      assert expired.config[:row_key] == "expired"
      assert expired.config[:example] == %{"card" => "expired"}
      assert "When paying with a expired card" in expired.config[:steps]
      assert stolen.config[:row_key] == "stolen"
      assert "When paying with a stolen card" in stolen.config[:steps]
    end

    test "verdict_format defaults to cucumber_json and scenario_map is accepted" do
      path =
        feature_file("""
        Feature: F
          Scenario: S
            Given x
        """)

      assert {:ok, goal} =
               Loader.from_map(
                 goal(%{
                   "provider" => "gherkin",
                   "feature" => path,
                   "verdict_format" => "scenario_map",
                   "runner_cmd" => "bash",
                   "runner_args" => ["r.sh"]
                 })
               )

      [pred] = goal.predicates
      assert pred.config[:verdict_format] == "scenario_map"
    end

    test "acceptance intent on the parent is inherited by every sub-predicate" do
      path =
        feature_file("""
        Feature: F
          Scenario: A
            Given x
          Scenario: B
            Given y
        """)

      assert {:ok, goal} =
               Loader.from_map(
                 goal(%{
                   "provider" => "gherkin",
                   "feature" => path,
                   "acceptance" => true,
                   "runner_cmd" => "bash",
                   "runner_args" => ["r.sh"]
                 })
               )

      assert Enum.all?(goal.predicates, & &1.acceptance?)
    end

    test "an optional report_path is carried onto every sub-predicate's config" do
      path =
        feature_file("""
        Feature: F
          Scenario: S
            Given x
        """)

      assert {:ok, goal} =
               Loader.from_map(
                 goal(%{
                   "provider" => "gherkin",
                   "feature" => path,
                   "report_path" => "build/cucumber.json",
                   "runner_cmd" => "bash",
                   "runner_args" => ["r.sh"]
                 })
               )

      [pred] = goal.predicates
      assert pred.config[:report_path] == "build/cucumber.json"
    end
  end

  describe "deterministic, stable ids across reloads (upsert, no duplicates)" do
    test "re-loading the same feature yields the identical id set" do
      path =
        feature_file("""
        Feature: F
          Scenario: A
            Given x
          Scenario: B
            Given y
        """)

      raw =
        goal(%{
          "provider" => "gherkin",
          "feature" => path,
          "runner_cmd" => "bash",
          "runner_args" => ["r.sh"]
        })

      {:ok, g1} = Loader.from_map(raw)
      {:ok, g2} = Loader.from_map(raw)

      ids1 = Enum.map(g1.predicates, & &1.id)
      ids2 = Enum.map(g2.predicates, & &1.id)
      assert ids1 == ids2
      # No duplicates within a single expansion.
      assert ids1 == Enum.uniq(ids1)
    end
  end

  describe "named load errors" do
    test "a missing feature key fails load with a named error" do
      assert {:error, reason} =
               Loader.from_map(goal(%{"provider" => "gherkin", "runner_cmd" => "bash"}))

      assert reason =~ "missing required key \"feature\""
    end

    test "an invalid verdict_format fails load with a named error" do
      path =
        feature_file("""
        Feature: F
          Scenario: S
            Given x
        """)

      assert {:error, reason} =
               Loader.from_map(
                 goal(%{
                   "provider" => "gherkin",
                   "feature" => path,
                   "verdict_format" => "junit_xml",
                   "runner_cmd" => "bash"
                 })
               )

      assert reason =~ "unknown verdict_format"
      assert reason =~ "cucumber_json"
    end

    test "an unreadable feature file fails load with a named error" do
      assert {:error, reason} =
               Loader.from_map(
                 goal(%{
                   "provider" => "gherkin",
                   "feature" => "/no/such/kazi-gherkin-missing.feature",
                   "runner_cmd" => "bash"
                 })
               )

      assert reason =~ "could not be read"
    end

    test "a feature with no runnable Scenario fails load with a named error" do
      path = feature_file("Feature: Empty\n")

      assert {:error, reason} =
               Loader.from_map(
                 goal(%{"provider" => "gherkin", "feature" => path, "runner_cmd" => "bash"})
               )

      assert reason =~ "no runnable Scenario"
    end
  end

  describe "provider evaluation (T62.1 scope: honest :unknown until T62.2)" do
    test "the gherkin provider evaluates to :unknown, never a fabricated pass" do
      pred =
        Predicate.new("f__s", :gherkin,
          config: %{feature: "f.feature", scenario: "S", runner_cmd: "bash"}
        )

      assert %PredicateResult{status: :unknown} =
               Kazi.Providers.Gherkin.evaluate(pred, %{})
    end
  end

  describe "non-gherkin predicates are untouched" do
    test "a goal with no gherkin entry loads byte-identically" do
      assert {:ok, goal} =
               Loader.from_map(
                 goal(%{"id" => "p", "provider" => "custom_script", "cmd" => "true"})
               )

      assert [%Predicate{id: "p", kind: :custom_script}] = goal.predicates
      assert goal.groups == []
    end
  end
end

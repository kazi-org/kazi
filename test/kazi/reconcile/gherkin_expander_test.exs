defmodule Kazi.Reconcile.GherkinExpanderTest do
  # ADR-0071: the runtime expander enumerates one sub-predicate per Scenario, and
  # one per Examples ROW for a Scenario Outline (unlike the author-time importer,
  # which collapses an outline to one scaffold). Pure, deterministic.
  use ExUnit.Case, async: true

  alias Kazi.Reconcile.GherkinExpander

  test "a plain Scenario expands to one entry with the importer id scheme" do
    feature = """
    Feature: Sign Up
      Scenario: A new user signs up
        Given a visitor
        Then an account exists
    """

    {:ok, [entry]} = GherkinExpander.expand(feature)

    assert entry.id == "sign-up__a-new-user-signs-up"
    assert entry.feature == "Sign Up"
    assert entry.scenario == "A new user signs up"
    assert entry.steps == ["Given a visitor", "Then an account exists"]
    refute entry.outline?
    assert entry.example == nil
  end

  test "a Scenario Outline expands to one entry PER Examples row, with substitution" do
    feature = """
    Feature: Checkout
      Scenario Outline: Payment declined for <card>
        Given a basket
        When paying with a <card> card
        Then the payment is declined

        Examples:
          | card    |
          | expired |
          | stolen  |
    """

    {:ok, entries} = GherkinExpander.expand(feature)

    assert length(entries) == 2

    ids = Enum.map(entries, & &1.id)

    assert ids == [
             "checkout__payment-declined-for-card__expired",
             "checkout__payment-declined-for-card__stolen"
           ]

    expired = hd(entries)
    assert expired.outline?
    assert expired.example == %{"card" => "expired"}
    assert expired.row_key == "expired"
    # `<card>` is substituted in the steps for this row.
    assert "When paying with a expired card" in expired.steps
    assert expired.scenario == "Payment declined for <card>"
  end

  test "a multi-column Examples table keys rows by the joined cell values" do
    feature = """
    Feature: Grid
      Scenario Outline: cell <x>,<y>
        Then ok
        Examples:
          | x | y |
          | 1 | 2 |
          | 3 | 4 |
    """

    {:ok, entries} = GherkinExpander.expand(feature)
    assert Enum.map(entries, & &1.row_key) == ["1-2", "3-4"]
    assert Enum.at(entries, 1).example == %{"x" => "3", "y" => "4"}
  end

  test "plain and outline scenarios coexist in document order, grouped by feature" do
    feature = """
    Feature: Mixed
      Scenario: first plain
        Then ok

      Scenario Outline: templated <n>
        Then ok
        Examples:
          | n |
          | a |
          | b |
    """

    {:ok, entries} = GherkinExpander.expand(feature)

    assert Enum.map(entries, & &1.id) == [
             "mixed__first-plain",
             "mixed__templated-n__a",
             "mixed__templated-n__b"
           ]

    assert Enum.all?(entries, &(&1.feature == "Mixed"))
  end

  test "a Scenario Outline with no Examples rows yields no entries (nothing to run)" do
    feature = """
    Feature: Empty outline
      Scenario Outline: nothing
        Then ok
        Examples:
          | col |
    """

    assert {:error, reason} = GherkinExpander.expand(feature)
    assert reason =~ "no runnable Scenario"
  end

  test "empty / scenario-less input is a tagged error, not a crash" do
    assert {:error, _} = GherkinExpander.expand("")
    assert {:error, _} = GherkinExpander.expand("Feature: F\n  # no scenarios\n")
    assert {:error, _} = GherkinExpander.expand(%{not: "a string"})
  end

  test "deterministic: the same feature yields identical entries" do
    feature = "Feature: D\n  Scenario: s\n    Then ok\n"
    assert GherkinExpander.expand(feature) == GherkinExpander.expand(feature)
  end
end

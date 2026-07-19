defmodule Kazi.Scenario.SourceTest do
  use ExUnit.Case, async: true

  alias Kazi.Scenario.Source

  doctest Kazi.Scenario.Source

  @feature """
  @billing
  Feature: Checkout

    # the happy path
    Scenario: A user checks out
      Given a cart with one item
      When the user submits the order
      And the payment clears
      Then the order is confirmed
      But no receipt is emailed

    Scenario: A user abandons the cart
      Given a cart with one item
      When the user leaves
      Then the cart is retained

    Scenario: A guest checks out
      Given an anonymous session
      When the guest submits the order
      Then the order is confirmed
  """

  describe "extract/2" do
    test "extracts the named Scenario from a 3-scenario Feature" do
      assert {:ok, extracted} = Source.extract(@feature, "A user abandons the cart")

      assert extracted.feature == "Checkout"
      assert extracted.scenario == "A user abandons the cart"

      assert Enum.map(extracted.steps, & &1.text) == [
               "a cart with one item",
               "the user leaves",
               "the cart is retained"
             ]
    end

    test "splits each step into keyword and text" do
      assert {:ok, extracted} = Source.extract(@feature, "A guest checks out")

      assert extracted.steps == [
               %{keyword: "Given", text: "an anonymous session", class: :given},
               %{keyword: "When", text: "the guest submits the order", class: :when},
               %{keyword: "Then", text: "the order is confirmed", class: :then}
             ]
    end

    test "And after When classifies :when and But after Then classifies :then" do
      assert {:ok, extracted} = Source.extract(@feature, "A user checks out")

      assert Enum.map(extracted.steps, &{&1.keyword, &1.class}) == [
               {"Given", :given},
               {"When", :when},
               {"And", :when},
               {"Then", :then},
               {"But", :then}
             ]
    end

    test "And after Given inherits :given" do
      feature = """
      Feature: Setup
        Scenario: Two givens
          Given a user
          And a session
          When they act
          Then it holds
      """

      assert {:ok, extracted} = Source.extract(feature, "Two givens")

      assert Enum.map(extracted.steps, &{&1.keyword, &1.class}) == [
               {"Given", :given},
               {"And", :given},
               {"When", :when},
               {"Then", :then}
             ]
    end

    test "a `*` bullet inherits the previous primary keyword's class" do
      feature = """
      Feature: Bullets
        Scenario: Starred
          Given a user
          When they act
          * they act again
          Then it holds
      """

      assert {:ok, extracted} = Source.extract(feature, "Starred")

      assert Enum.map(extracted.steps, &{&1.keyword, &1.class}) == [
               {"Given", :given},
               {"When", :when},
               {"*", :when},
               {"Then", :then}
             ]
    end

    test "a leading And with no preceding primary keyword defaults to :given" do
      feature = """
      Feature: Malformed
        Scenario: Leading and
          And a user
          Then it holds
      """

      assert {:ok, extracted} = Source.extract(feature, "Leading and")

      assert Enum.map(extracted.steps, &{&1.keyword, &1.class}) == [
               {"And", :given},
               {"Then", :then}
             ]
    end

    test "returns {:error, :scenario_not_found} for an absent Scenario" do
      assert Source.extract(@feature, "A user refunds the order") ==
               {:error, :scenario_not_found}
    end

    test "matches a Scenario Outline by name" do
      feature = """
      Feature: Outlines
        Scenario Outline: A user signs in
          Given a <role>
          When they sign in
          Then they land on <page>

          Examples:
            | role  | page      |
            | admin | dashboard |
      """

      assert {:ok, extracted} = Source.extract(feature, "A user signs in")
      assert extracted.scenario == "A user signs in"

      assert Enum.map(extracted.steps, & &1.text) == [
               "a <role>",
               "they sign in",
               "they land on <page>"
             ]
    end

    test "an unnamed Scenario is addressable as \"Scenario\"" do
      feature = """
      Feature: Anonymous
        Scenario:
          Given a user
          Then it holds
      """

      assert {:ok, extracted} = Source.extract(feature, "Scenario")
      assert extracted.scenario == "Scenario"
    end

    test "a Feature-less Scenario extracts with a nil feature" do
      feature = """
      Scenario: Orphan
        Given a user
        Then it holds
      """

      assert {:ok, extracted} = Source.extract(feature, "Orphan")
      assert extracted.feature == nil
    end

    test "Background steps are not attributed to a Scenario" do
      feature = """
      Feature: Backgrounds
        Background:
          Given a tenant

        Scenario: Real one
          Given a user
          Then it holds
      """

      assert {:ok, extracted} = Source.extract(feature, "Real one")
      assert Enum.map(extracted.steps, & &1.text) == ["a user", "it holds"]
    end

    test "a duplicated Scenario name resolves to the first in document order" do
      feature = """
      Feature: Dupes
        Scenario: Same
          Given the first
          Then it holds

        Scenario: Same
          Given the second
          Then it holds
      """

      assert {:ok, extracted} = Source.extract(feature, "Same")
      assert Enum.map(extracted.steps, & &1.text) == ["the first", "it holds"]
    end
  end

  describe "normalize/1" do
    test "keeps keywords, trims lines and collapses internal whitespace" do
      {:ok, extracted} = Source.extract(@feature, "A guest checks out")

      assert Source.normalize(extracted) == """
             Scenario: A guest checks out
             Given an anonymous session
             When the guest submits the order
             Then the order is confirmed\
             """
    end
  end

  describe "sha/1" do
    test "is a lowercase hex SHA-256" do
      {:ok, extracted} = Source.extract(@feature, "A guest checks out")
      sha = Source.sha(extracted)

      assert String.length(sha) == 64
      assert sha =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "is stable under comment, tag and whitespace churn" do
      churned = """
      @billing @slow
      Feature: Checkout

        # a brand new comment
        # and another

        @wip
        Scenario:    A guest checks out
              Given     an anonymous session
          # an interleaved comment
          When the guest submits    the order

          Then the order   is confirmed
      """

      {:ok, original} = Source.extract(@feature, "A guest checks out")
      {:ok, churned} = Source.extract(churned, "A guest checks out")

      assert Source.sha(churned) == Source.sha(original)
    end

    test "changes when a step's text changes" do
      edited = String.replace(@feature, "an anonymous session", "an expired session")

      {:ok, original} = Source.extract(@feature, "A guest checks out")
      {:ok, edited} = Source.extract(edited, "A guest checks out")

      refute Source.sha(edited) == Source.sha(original)
    end

    test "changes when a step is added" do
      before = """
      Feature: Checkout
        Scenario: A guest checks out
          Given an anonymous session
          Then the order is confirmed
      """

      after_ = """
      Feature: Checkout
        Scenario: A guest checks out
          Given an anonymous session
          And the totals are charged
          Then the order is confirmed
      """

      {:ok, original} = Source.extract(before, "A guest checks out")
      {:ok, edited} = Source.extract(after_, "A guest checks out")

      refute Source.sha(edited) == Source.sha(original)
    end

    test "distinguishes two Scenarios that share their steps" do
      feature = """
      Feature: Twins
        Scenario: First
          Given a user
          Then it holds

        Scenario: Second
          Given a user
          Then it holds
      """

      {:ok, first} = Source.extract(feature, "First")
      {:ok, second} = Source.extract(feature, "Second")

      refute Source.sha(first) == Source.sha(second)
    end

    test "is independent of the enclosing Feature name" do
      renamed = String.replace(@feature, "Feature: Checkout", "Feature: Order placement")

      {:ok, original} = Source.extract(@feature, "A guest checks out")
      {:ok, renamed} = Source.extract(renamed, "A guest checks out")

      assert Source.sha(renamed) == Source.sha(original)
    end
  end
end

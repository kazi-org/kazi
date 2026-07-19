# A small Cucumber/gherkin fixture for Kazi.Reconcile.GherkinImporter (T13.2).
# Three features (one a spelling variant of another so the importer must
# collapse them into one group) plus a feature with a blank name (-> the
# default "ungrouped" group).

@checkout
Feature: Checkout
  As a shopper I can pay for the items in my basket.

  Background:
    Given the store catalogue is loaded

  @smoke
  Scenario: A shopper checks out a basket
    Given a basket with two items
    When the shopper pays with a valid card
    Then the order is confirmed
    And a receipt is emailed

  Scenario Outline: Payment is declined for a bad card
    Given a basket with one item
    When the shopper pays with a <card>
    Then the payment is declined

    Examples:
      | card          |
      | expired card  |
      | stolen card   |

Feature: Sign Up
  Scenario: A new user signs up
    Given a visitor on the home page
    When they submit the sign-up form
    Then their account is created

Feature: sign-up
  Scenario: An existing email is rejected
    Given an account already exists for the email
    When a visitor submits the sign-up form with that email
    Then the sign-up is rejected

Feature:
  Scenario: The health endpoint responds
    Then the service reports healthy

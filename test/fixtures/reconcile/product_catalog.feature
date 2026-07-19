# A TAGGED product-scope behavior spec for Kazi.Reconcile.GherkinImporter
# (T41.1, ADR-0054): Scenarios ARE use cases, tagged with kazi's vocabulary
# layered on real Cucumber tag syntax. Exercises Feature-level tag inheritance,
# Scenario-level override, every recognized interface, and house tags outside
# kazi's vocabulary (which must be ignored, never an error).

@product @owner:growth
@role:shopper
Feature: Storefront

  # Inherits @role:shopper from the Feature; adds its own interface/priority.
  @interface:web @priority:P0
  Scenario: A shopper checks out a basket
    Given a basket with two items
    When the shopper pays with a valid card
    Then the order is confirmed

  # Overrides the Feature-level role; an api use case.
  @interface:api @priority:P1 @role:partner
  Scenario: A partner queries order status
    Given an order exists
    When the partner GETs the order endpoint
    Then the order status is returned

  # A house tag kazi does not know, plus a malformed priority — both ignored.
  @wip @priority:P9
  Scenario: A shopper browses the catalogue
    Given a catalogue with items
    Then the items are listed

Feature: Operator tooling

  @interface:cli @priority:P2 @role:operator
  Scenario: An operator lists releases
    Given a configured workspace
    When the operator runs the list command
    Then the releases are printed

# A worked behavior spec (ADR-0050, T40.1). This is `kazi spec import`'s OWN
# acceptance, expressed as Gherkin — dogfooding the tier from day one. It parses
# cleanly through Kazi.Reconcile.GherkinImporter (pinned by an ExUnit test), and
# each Scenario below becomes one custom_script acceptance predicate (a scaffold,
# RED until its runner is wired) grouped under this Feature.

Feature: Import a behavior spec into a goal

  Scenario: A new spec derives predicates into a fresh goal-file
    Given a docs/specs/*.feature behavior spec
    When a contributor runs kazi spec import --into a non-existent goal-file
    Then the goal-file is created
    And it carries one custom_script acceptance predicate per Scenario
    And the predicates are grouped by their Feature

  Scenario: Re-importing the same spec upserts rather than duplicates
    Given a goal-file already imported from a behavior spec
    When the same behavior spec is imported again
    Then each predicate keeps its Feature-plus-Scenario derived id
    And no duplicate predicate is created

  Scenario: A hand-authored live predicate survives a re-import
    Given a goal-file with a hand-added live http_probe predicate
    When the behavior spec is re-imported into that goal-file
    Then the spec-derived predicates are upserted
    And the hand-added live predicate is preserved untouched

  Scenario: The machine surface emits the upserted predicate ids
    Given a behavior spec and a target goal-file
    When kazi spec import is run with the --json flag
    Then it prints one decodable JSON object
    And the object lists the upserted predicate ids

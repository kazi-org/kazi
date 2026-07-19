# Product-scope behavior spec (T41.2, ADR-0054) — the SAME docs/specs/ tier as a
# task spec (ADR-0050), used at the capability scope: one Feature per capability,
# one Scenario per use case, tagged with the T41.1 vocabulary.
#
# Feature tags are inherited by every Scenario, so the domain's role/priority are
# declared once here and a Scenario overrides only where it genuinely differs.

@role:operator
@priority:P0
@interface:cli
Feature: Goal convergence
  An operator declares "done" as machine-checkable predicates and kazi drives a
  coding harness until they are objectively true, stuck, or over budget. Truth
  lives in the predicate vector, never in the model doing the keystrokes.

  Scenario: A goal whose predicates already hold converges without dispatching
    Given a goal whose predicates all pass against the workspace
    When the operator applies the goal
    Then kazi reports converged
    And no harness dispatch is made

  Scenario: A failing predicate drives the harness until it holds
    Given a goal with one failing code predicate
    When the operator applies the goal
    Then kazi dispatches the harness against the failing predicate
    And kazi re-observes the predicate after the dispatch
    And kazi reports converged once the predicate holds

  Scenario: A persistently failing set stops as stuck rather than looping forever
    Given a goal whose failing predicate set does not change across the stuck window
    When the operator applies the goal
    Then kazi stops and reports stuck
    And the terminal result names the failing predicate ids

  Scenario: A run that exceeds its budget stops and says which dimension
    Given a goal with a max_iterations budget of one
    When the operator applies the goal and the predicate still fails
    Then kazi stops and reports over_budget
    And the terminal result names the exceeded budget dimension

  # A refused harness cannot converge by grinding — the diagnosis must be legible
  # rather than looking like ordinary difficulty (T54.6, #1072, lore L-0023).
  Scenario: A harness whose tool calls are denied self-diagnoses instead of burning budget
    Given a harness whose tool calls are all denied
    When the operator applies the goal
    Then kazi stops after the first denied dispatch
    And the terminal result names the denied tool calls

  # The honesty backstop: the whole point of objective termination is that a cheap
  # implementer cannot declare victory on plausible-but-wrong work.
  @priority:P1
  Scenario: A harness claiming success cannot converge a goal whose predicates still fail
    Given a harness that reports success without changing the workspace
    When the operator applies the goal
    Then kazi re-observes the predicates itself
    And kazi does not report converged

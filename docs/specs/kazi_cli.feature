# kazi's OWN capabilities as scenario predicates (T49.13, ADR-0064; verifies
# UC-066/UC-067). Each Scenario below binds to a committed pin
# (docs/specs/pins/) and is replayed by the scenario predicate against the
# RELEASED kazi binary (the `@interface:cli` Scenario, cli surface) or a running
# `kazi dashboard` (the `@interface:web` Scenario, browser surface). The pin is
# the grader: a Scenario is green only when the surface provider observes the
# capability on replay, never because an agent claimed it (the truth invariant).
#
# Goal-file: priv/examples/kazi_capabilities.goal.toml. See
# docs/scenario-predicate.md for the pin reference and the demonstrate-then-pin
# workflow.

Feature: kazi command-line capabilities

  @interface:cli @role:operator @priority:P0
  Scenario: A user inits plans approves and applies a hello goal
    Given kazi is installed on the PATH
    When the operator initialises a goal file from the repo
    And the operator drafts a hello-goal proposal
    And the operator approves the proposal
    And the operator applies the hello goal in check mode
    Then kazi reports the hello goal converged to pass

  @interface:web @role:operator @priority:P1
  Scenario: An operator sees mission control in the dashboard
    Given the kazi dashboard is running
    When the operator opens mission control
    Then the fleet view is shown

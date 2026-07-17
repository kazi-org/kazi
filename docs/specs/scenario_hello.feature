# A worked, replayable `scenario` predicate example (ADR-0064, T49.5). This
# Feature is bound by priv/examples/scenario_hello.goal.toml to a committed pin
# (docs/specs/pins/scenario-hello__a-visitor-sees-the-greeting.pin.json) that
# replays green against the repo-local fixture page
# priv/examples/scenario_hello_fixture.html. See docs/scenario-predicate.md.

Feature: Scenario hello

  Scenario: A visitor sees the greeting
    Given the greeting page is open
    Then the greeting is shown

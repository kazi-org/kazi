Feature: Surface fixture is fully documented
  Every element the surface scanner finds in test/fixtures/surface is
  referenced here by its symbol/task name, so manifest-coverage passes.

  Scenario: Arithmetic surface
    Given a caller
    When it invokes `Surface.Calc.add/2`
    And it invokes `Surface.Calc.zero/0`
    Then `Surface.Calc.double/1` doubles its argument

  Scenario: Nested module surface
    When `Surface.Outer.top/1` is called with an integer
    Then `Surface.Outer.Inner.deep/3` returns a triple

  Scenario: The greet mix task
    When the operator runs `mix surface.greet`
    Then `Mix.Tasks.Surface.Greet.run/1` prints a greeting

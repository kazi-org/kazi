defmodule Kazi.Examples.ScenarioHelloExampleTest do
  # The worked scenario-predicate example (ADR-0064, T49.5) is REAL, not
  # illustrative: the committed goal-file loads, the committed pin validates
  # against the current Scenario through the genuine T49.1 classifier, and the
  # pin replays green through the T49.3 provider — the browser delegate stubbed
  # via the same stub_playwright.sh seam the provider tests use, so CI stays
  # hermetic while the pin remains genuinely replayable against the repo-local
  # fixture page.
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Goal.Loader
  alias Kazi.Providers.Scenario
  alias Kazi.Scenario.{Pin, Source}

  @root Path.expand("../../..", __DIR__)
  @goal Path.join(@root, "priv/examples/scenario_hello.goal.toml")
  @feature_path Path.join(@root, "docs/specs/scenario_hello.feature")
  @pin Path.join(@root, "docs/specs/pins/scenario-hello__a-visitor-sees-the-greeting.pin.json")
  @fixture_url "http://localhost:8080/scenario_hello_fixture.html"
  @scenario_name "A visitor sees the greeting"
  @stub Path.expand("../../support/stub_playwright.sh", __DIR__)

  test "the example goal-file loads clean as a scenario predicate" do
    assert {:ok, goal} = Loader.load(@goal)
    assert [%Predicate{kind: :scenario, config: config}] = goal.predicates
    assert config.spec == "docs/specs/scenario_hello.feature"
    assert config.scenario == @scenario_name
    assert config.surface == "browser"
  end

  test "the committed pin passes T49.1 validation (classifies :pinned)" do
    {:ok, scenario} = Source.extract(File.read!(@feature_path), @scenario_name)
    contents = File.read!(@pin)
    {:ok, pin} = Pin.parse(contents)

    assert Pin.classify(contents, pin, scenario, sha_fun: &Source.sha/1) == :pinned
  end

  test "the pinned scenario replays green through the stub runner path" do
    {:ok, goal} = Loader.load(@goal)
    [predicate] = goal.predicates

    verdict =
      Jason.encode!(%{
        status: "pass",
        url: @fixture_url,
        assertions: [
          %{type: "visible", selector: "#greeting", ok: true},
          %{
            type: "text",
            selector: "#greeting",
            ok: true,
            expected: "Hello, kazi!",
            found: "Hello, kazi!"
          }
        ],
        screenshot: nil,
        error: nil
      })

    config = Map.merge(predicate.config, %{cmd: @stub, args: [], env: [{"STUB_JSON", verdict}]})
    result = Scenario.evaluate(%{predicate | config: config}, %{workspace: @root})

    assert %PredicateResult{status: :pass} = result
    assert result.evidence.pin_state == :pinned
    assert result.evidence.scenario == @scenario_name
    assert result.evidence.surface == "browser"
  end
end

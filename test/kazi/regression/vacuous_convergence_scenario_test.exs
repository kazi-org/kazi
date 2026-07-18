defmodule Kazi.Regression.VacuousConvergenceScenarioTest do
  # T57.3 re-verification of issue #924 against the shipped E49 scenario-predicate
  # mechanism (ADR-0064). #924 recorded a UI+backend+integration feature that
  # "converged" green while the feature was largely unbuilt: the acceptance
  # predicates were `custom_script` greps, and a grep passes whenever its literal
  # appears ANYWHERE — including an unrelated pre-existing comment. This test
  # reproduces that exact failure shape and then re-authors the SAME capability as
  # a `scenario` predicate to record whether E49 closes the failure class.
  #
  # It is a real boundary test: the raw grep runs through the genuine
  # Kazi.Providers.CustomScript System.cmd path, and the scenario predicate runs
  # through the genuine Kazi.Providers.Scenario classify -> resolve -> delegate
  # path, with the browser surface stubbed by the shipped stub_playwright.sh (the
  # same seam scenario_test.exs uses). No browser, no network.
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.{CustomScript, Scenario}
  alias Kazi.Scenario.Source

  @stub Path.expand("../../support/stub_playwright.sh", __DIR__)

  # #924's real failure-mode 2, verbatim in shape: the ONLY occurrence of the
  # feature word in the integration package is a pre-existing comment that has
  # nothing to do with the new capability. The coach context-builder never loads
  # or injects the onboarding profile; there is no client call to the backend.
  @unrelated_preexisting_source """
  package ai

  // NOTE: there is no onboarding or Settings surface yet, so the context
  // builder returns the base system prompt unchanged.
  func BuildContext(base string) string {
  \treturn base
  }
  """

  # The capability #924 believed it was verifying, expressed as a tagged Gherkin
  # Scenario (ADR-0054 / ADR-0064): a real, observable end-to-end behavior.
  @feature """
  @onboarding @interface:web
  Feature: Coach onboarding integration

    Scenario: The coach injects the onboarding profile
      Given a member has completed onboarding
      When the coach builds its reply
      Then the reply reflects the onboarding profile
  """

  @scenario_name "The coach injects the onboarding profile"
  @surface_url "https://example.test/coach/reply"

  setup do
    dir =
      Path.join(System.tmp_dir!(), "kazi_vacuous_924_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(dir, "internal/ai"))
    File.write!(Path.join(dir, "internal/ai/context.go"), @unrelated_preexisting_source)

    spec_path = Path.join(dir, "coach.feature")
    File.write!(spec_path, @feature)

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir, spec_path: spec_path}
  end

  defp scenario_sha do
    {:ok, scenario} = Source.extract(@feature, @scenario_name)
    Source.sha(scenario)
  end

  defp pin_json(overrides) do
    Map.merge(
      %{
        "pin_version" => 1,
        "spec" => "coach.feature",
        "scenario" => @scenario_name,
        "scenario_sha" => scenario_sha(),
        "surface" => "browser",
        # minted commit absent: a red replay stays a plain :fail rather than being
        # reclassified as :code_drift (which needs a moved HEAD to trigger).
        "minted" => %{},
        "inputs" => %{},
        "trace" => %{
          "url" => @surface_url,
          "steps" => [%{"action" => "click", "selector" => "#ask-coach"}],
          "assertions" => [
            %{"type" => "text", "selector" => "#reply", "contains" => "onboarding"}
          ]
        },
        "map" => [
          %{"step" => "the coach builds its reply", "steps" => [0], "assertions" => []},
          %{
            "step" => "the reply reflects the onboarding profile",
            "steps" => [],
            "assertions" => [0]
          }
        ]
      },
      overrides
    )
  end

  defp write_pin!(dir, json) do
    path = Path.join(dir, "coach.pin.json")
    File.write!(path, Jason.encode!(json))
    path
  end

  defp scenario_predicate(spec_path, pin_path, passthrough) do
    config =
      Map.merge(%{spec: spec_path, scenario: @scenario_name, pin: pin_path}, passthrough)

    Predicate.new("coach-onboarding", :scenario, config: config)
  end

  # --- Half 1: the raw predicate reproduces #924's vacuous pass -----------------

  test "RAW custom_script grep passes VACUOUSLY though the feature is unbuilt", %{
    workspace: ws
  } do
    # The exact predicate shape from #924: `grep -rqiE '<feature-word>' <pkg>`,
    # compounded with a build/test gate. It exits 0 because the word appears in an
    # unrelated pre-existing comment — the feature itself does not exist.
    predicate =
      Predicate.new(:coach_wired, :custom_script,
        config: %{
          cmd: "sh",
          args: ["-c", "grep -rqiE 'onboarding' internal/ai"]
        }
      )

    result = CustomScript.evaluate(predicate, %{workspace: ws})

    # This is the bug: a green verdict with no real work behind it.
    assert %PredicateResult{status: :pass} = result,
           "expected the grep to vacuously pass on the unrelated comment (reproducing #924)"
  end

  # --- Half 2: the scenario predicate for the SAME capability cannot pass vacuously

  test "SCENARIO predicate for the same capability FAILS when the feature is unbuilt (unpinned)",
       %{workspace: ws, spec_path: spec} do
    # An unbuilt feature has no committed pin. There is no string to stuff and no
    # comment to match: the only path to a pass is a validated pin that replays
    # green through the surface, and there is none.
    missing_pin = Path.join(ws, "coach.pin.json")

    result =
      Scenario.evaluate(
        scenario_predicate(spec, missing_pin, %{}),
        %{workspace: ws}
      )

    assert %PredicateResult{status: :fail} = result
    assert result.evidence.pin_state == :unpinned
  end

  test "SCENARIO predicate cannot be satisfied by a fabricated pin: a red surface replay FAILS",
       %{workspace: ws, spec_path: spec} do
    # Even if an author fabricates a valid-looking pin (correct scenario hash,
    # well-formed trace), it can ONLY pass by replaying green through the surface
    # provider. The unbuilt UI shows no onboarding-derived reply, so the stubbed
    # surface returns a RED verdict and the predicate fails. No amount of pin
    # authorship substitutes for the surface observation (the ADR-0064 truth
    # invariant) — this is exactly what a grep could NOT enforce.
    red_verdict =
      Jason.encode!(%{
        status: "fail",
        url: @surface_url,
        assertions: [
          %{type: "text", selector: "#reply", ok: false, expected: "onboarding", found: ""}
        ],
        screenshot: nil,
        error: nil
      })

    pin_path = write_pin!(ws, pin_json(%{}))

    result =
      Scenario.evaluate(
        scenario_predicate(spec, pin_path, %{
          cmd: @stub,
          args: [],
          env: [{"STUB_JSON", red_verdict}]
        }),
        %{workspace: ws}
      )

    assert %PredicateResult{status: :fail} = result
  end

  # --- Positive control: a pass IS reachable, but only through the surface -------

  test "SCENARIO predicate passes ONLY when the surface actually demonstrates the behavior",
       %{workspace: ws, spec_path: spec} do
    # The built-feature case: the surface provider observes the onboarding-derived
    # reply, so the replay is green and the predicate passes. Proof that the
    # mechanism is not merely always-red: pass is reachable, but its truth-maker is
    # the surface observation, never a string match.
    green_verdict =
      Jason.encode!(%{
        status: "pass",
        url: @surface_url,
        assertions: [
          %{
            type: "text",
            selector: "#reply",
            ok: true,
            expected: "onboarding",
            found: "Because you told us during onboarding..."
          }
        ],
        screenshot: nil,
        error: nil
      })

    pin_path = write_pin!(ws, pin_json(%{}))

    result =
      Scenario.evaluate(
        scenario_predicate(spec, pin_path, %{
          cmd: @stub,
          args: [],
          env: [{"STUB_JSON", green_verdict}]
        }),
        %{workspace: ws}
      )

    assert %PredicateResult{status: :pass} = result
    assert result.evidence.pin_state == :pinned
    assert result.evidence.scenario == @scenario_name
  end
end

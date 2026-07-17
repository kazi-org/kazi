defmodule Kazi.Providers.ScenarioTest do
  # Tier 2: real boundary. The scenario provider DELEGATES to a surface provider;
  # the correct integration test replays a pinned trace through the genuine
  # Kazi.Providers.Browser subprocess seam with the shipped stub program
  # (test/support/stub_playwright.sh), exactly as browser_test.exs does — no
  # browser runs, but the real classify → resolve → delegate → extend path does
  # (T49.3, ADR-0064, UC-066).
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Goal.Loader
  alias Kazi.Providers.Scenario
  alias Kazi.Scenario.Source

  @stub Path.expand("../../support/stub_playwright.sh", __DIR__)

  @feature """
  @billing
  Feature: Personal access tokens

    # the happy path
    Scenario: User can create and download a PAT
      Given I am signed in
      When I create a token
      Then the token value is shown
  """

  @scenario_name "User can create and download a PAT"
  @trace_url "https://example.test/settings/tokens"

  # Interned at compile so String.to_existing_atom/1 resolves it in the
  # unregistered-surface test — an atom that exists but is not a provider kind.
  @unknown_surface :kazi_scenario_unknown_surface

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_scenario_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    spec_path = Path.join(dir, "pat.feature")
    File.write!(spec_path, @feature)

    {:ok, workspace: dir, spec_path: spec_path}
  end

  defp scenario_sha do
    {:ok, scenario} = Source.extract(@feature, @scenario_name)
    Source.sha(scenario)
  end

  defp browser_trace(extra) do
    Map.merge(
      %{
        "url" => @trace_url,
        "steps" => [%{"action" => "click", "selector" => "#new-token"}],
        "assertions" => [%{"type" => "visible", "selector" => "#token-value"}]
      },
      extra
    )
  end

  defp pin_json(overrides) do
    Map.merge(
      %{
        "pin_version" => 1,
        "spec" => "docs/specs/pat.feature",
        "scenario" => @scenario_name,
        "scenario_sha" => scenario_sha(),
        "surface" => "browser",
        "minted" => %{"commit" => "0f1e2d3c4b5a"},
        "inputs" => %{},
        "trace" => browser_trace(%{}),
        "map" => [
          %{"step" => "I create a token", "steps" => [0], "assertions" => []},
          %{"step" => "the token value is shown", "steps" => [], "assertions" => [0]}
        ]
      },
      overrides
    )
  end

  defp write_pin!(dir, json) do
    path = Path.join(dir, "pat.pin.json")
    File.write!(path, Jason.encode!(json))
    path
  end

  defp predicate(spec_path, pin_path, passthrough) do
    config = Map.merge(%{spec: spec_path, scenario: @scenario_name, pin: pin_path}, passthrough)
    Predicate.new("pat", :scenario, config: config)
  end

  defp evaluate(spec_path, pin_path, passthrough, context) do
    Scenario.evaluate(predicate(spec_path, pin_path, passthrough), context)
  end

  test "implements the PredicateProvider behaviour" do
    behaviours = Scenario.module_info(:attributes)[:behaviour] || []
    assert Kazi.PredicateProvider in behaviours
  end

  # --- Pinned: replay through the delegate --------------------------------------

  test "pinned + green stub -> :pass carrying the delegate's score", %{
    workspace: ws,
    spec_path: spec
  } do
    verdict =
      Jason.encode!(%{
        status: "pass",
        url: @trace_url,
        assertions: [%{type: "visible", selector: "#token-value", ok: true}],
        screenshot: nil,
        error: nil
      })

    seq = Path.join(ws, "seq.jsonl")
    File.write!(seq, verdict <> "\n" <> verdict <> "\n")

    pin_path = write_pin!(ws, pin_json(%{"trace" => browser_trace(%{"samples" => 2})}))

    result =
      evaluate(spec, pin_path, %{cmd: @stub, args: [], env: [{"STUB_SEQ_FILE", seq}]}, %{
        workspace: ws
      })

    assert %PredicateResult{status: :pass} = result
    # The delegate's envelope-v2 grading (2 consecutive passes) passes through verbatim.
    assert result.score == 2.0
    assert result.direction == :higher_better
    # Evidence is EXTENDED, not replaced: delegate url + scenario fields both present.
    assert result.evidence.url == @trace_url
    assert result.evidence.scenario == @scenario_name
    assert result.evidence.spec == spec
    assert result.evidence.surface == "browser"
    assert result.evidence.pin_state == :pinned
  end

  test "pinned + red stub -> :fail with the delegate's evidence PLUS the scenario fields",
       %{workspace: ws, spec_path: spec} do
    verdict =
      Jason.encode!(%{
        status: "fail",
        url: @trace_url,
        assertions: [
          %{
            type: "visible",
            selector: "#token-value",
            ok: false,
            expected: "visible",
            found: "hidden"
          }
        ],
        screenshot: nil,
        error: nil
      })

    pin_path = write_pin!(ws, pin_json(%{}))

    result =
      evaluate(spec, pin_path, %{cmd: @stub, args: [], env: [{"STUB_JSON", verdict}]}, %{
        workspace: ws
      })

    assert %PredicateResult{status: :fail} = result
    # The delegate's per-assertion evidence is preserved.
    [assertion] = result.evidence.assertions
    refute assertion["ok"]
    assert assertion["found"] == "hidden"
    # And the scenario fields are added on top.
    assert result.evidence.scenario == @scenario_name
    assert result.evidence.surface == "browser"
    assert result.evidence.pin_state == :pinned
  end

  # --- Non-pinned states are all :fail, each naming its pin_state ---------------

  test "an unpinned scenario -> :fail naming pin_state :unpinned", %{
    workspace: ws,
    spec_path: spec
  } do
    absent = Path.join(ws, "absent.pin.json")

    result = evaluate(spec, absent, %{}, %{workspace: ws})

    assert %PredicateResult{status: :fail} = result
    assert result.evidence.pin_state == :unpinned
    assert result.evidence.pin_path == absent
    assert result.evidence.reasons == []
    refute result.evidence.scenario_steps == []
  end

  test "a stale pin (sha mismatch) -> :fail naming pin_state {:stale, :spec_changed}",
       %{workspace: ws, spec_path: spec} do
    pin_path = write_pin!(ws, pin_json(%{"scenario_sha" => String.duplicate("b", 64)}))

    result = evaluate(spec, pin_path, %{}, %{workspace: ws})

    assert %PredicateResult{status: :fail} = result
    assert result.evidence.pin_state == {:stale, :spec_changed}
    assert result.evidence.reasons == [{:stale, :spec_changed}]
  end

  test "an invalid pin (unmapped Then step) -> :fail naming pin_state {:invalid, _}",
       %{workspace: ws, spec_path: spec} do
    map = [
      %{"step" => "I create a token", "steps" => [0], "assertions" => []},
      %{"step" => "the token value is shown", "steps" => [], "assertions" => []}
    ]

    pin_path = write_pin!(ws, pin_json(%{"map" => map}))

    result = evaluate(spec, pin_path, %{}, %{workspace: ws})

    assert %PredicateResult{status: :fail} = result
    assert {:invalid, reasons} = result.evidence.pin_state
    assert Enum.any?(reasons, &match?({:unmapped_then, _}, &1))
    assert result.evidence.reasons == reasons
  end

  # --- Error paths (distinct reasons) ------------------------------------------

  test "a missing spec file -> :error reason :spec_not_found", %{workspace: ws} do
    result =
      evaluate(Path.join(ws, "nope.feature"), Path.join(ws, "x.pin.json"), %{}, %{workspace: ws})

    assert %PredicateResult{status: :error} = result
    assert result.evidence.reason == :spec_not_found
  end

  test "a scenario name absent from the spec -> :error reason :scenario_not_found",
       %{workspace: ws, spec_path: spec} do
    config = %{spec: spec, scenario: "No such scenario", pin: Path.join(ws, "x.pin.json")}

    result = Scenario.evaluate(Predicate.new("pat", :scenario, config: config), %{workspace: ws})

    assert %PredicateResult{status: :error} = result
    assert result.evidence.reason == :scenario_not_found
  end

  test "a pinned scenario on an unregistered surface -> :error reason :surface_unavailable",
       %{workspace: ws, spec_path: spec} do
    _ = @unknown_surface
    pin_path = write_pin!(ws, pin_json(%{}))

    result =
      evaluate(
        spec,
        pin_path,
        %{surface: Atom.to_string(@unknown_surface), cmd: @stub, args: []},
        %{
          workspace: ws
        }
      )

    assert %PredicateResult{status: :error} = result
    assert result.evidence.reason == :surface_unavailable
    assert result.evidence.surface == Atom.to_string(@unknown_surface)
  end

  # --- Loader integration ------------------------------------------------------

  describe "goal loader" do
    defp scenario_goal(pred_overrides) do
      predicate =
        Map.merge(
          %{
            "id" => "pat",
            "provider" => "scenario",
            "spec" => "docs/specs/pat.feature",
            "scenario" => @scenario_name
          },
          pred_overrides
        )

      %{"id" => "g", "predicate" => [predicate]}
    end

    test "rejects a scenario predicate missing spec" do
      assert {:error, reason} = Loader.from_map(scenario_goal(%{"spec" => nil}))
      assert reason =~ "spec"
    end

    test "rejects a scenario predicate missing scenario" do
      predicate = %{"id" => "pat", "provider" => "scenario", "spec" => "docs/specs/pat.feature"}
      assert {:error, reason} = Loader.from_map(%{"id" => "g", "predicate" => [predicate]})
      assert reason =~ "scenario"
    end

    test "rejects an unknown surface enum" do
      assert {:error, reason} = Loader.from_map(scenario_goal(%{"surface" => "carrier-pigeon"}))
      assert reason =~ "surface"
    end

    test "accepts a well-formed scenario predicate" do
      assert {:ok, goal} = Loader.from_map(scenario_goal(%{"surface" => "browser"}))
      assert [%Predicate{kind: :scenario, config: config}] = goal.predicates
      assert config.spec == "docs/specs/pat.feature"
      assert config.scenario == @scenario_name
      assert config.surface == "browser"
    end
  end

  # --- Schema surface ----------------------------------------------------------

  test "kazi schema scenario lists the config keys" do
    assert {:ok, schema} = Kazi.Predicate.Schema.fetch("scenario")
    names = Enum.map(schema.keys, & &1.name)
    assert "spec" in names
    assert "scenario" in names
    assert "surface" in names
    assert "scenario" in Kazi.Predicate.Schema.kinds()
  end
end

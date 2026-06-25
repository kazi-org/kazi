defmodule Kazi.Providers.RecipeExamplesTest do
  @moduledoc """
  T32.9 (ADR-0043) acceptance: the security/contract/perf `custom_script` + ratchet
  RECIPES under priv/examples/ both PARSE (through the real loader, including the
  custom_script/ratchet key validation) and EVALUATE to the correct verdict against
  a representative fixture.

  Like the other example tests, each recipe's `cmd` names a real tool that is not
  installed here (buf, oasdiff, trufflehog, lighthouse, trivy, ...), so each test
  loads the recipe's DECLARED verdict/metric/direction, swaps ONLY the command for a
  fixture that emits the tool's envelope (or the chosen exit code), and asserts the
  verdict — proving the DECLARATION the recipe ships is correct.

  Covers the two evidence tiers and the exit-code gotchas:

    * DEMONSTRATION tier (fail directly): buf/oasdiff/pact contract breaks, a
      trufflehog `Verified:true` secret, a visual-regression diff.
    * PRESENCE/CLAIM tier (ratchet against a baseline): a perf-latency regression, an
      a11y-score regression, a new IaC-scan finding.
    * Exit-code gotcha: the trufflehog secret recipe and the trivy IaC recipe both
      gate on the PARSED output (a `match_count` and a ratchet metric), so the
      verdict holds even though the tool exits 0 WITH findings.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader
  alias Kazi.Predicate
  alias Kazi.Providers.{CustomScript, Ratchet}

  @examples Path.join([File.cwd!(), "priv", "examples"])

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_recipe_ex_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  # Load the single predicate config (and its kind) from a recipe file.
  defp recipe(name) do
    assert {:ok, %Goal{predicates: [%Predicate{kind: kind, id: id, config: config}]}} =
             Loader.load(Path.join(@examples, name))

    {kind, id, config}
  end

  # Evaluate a custom_script recipe's declared verdict, with cmd/args swapped to a
  # fixture that prints `out` and exits `code`.
  defp eval_script(config, out, code, ws) do
    config =
      Map.merge(config, %{cmd: "sh", args: ["-c", "printf '%s' '#{out}'; exit #{code}"]})

    CustomScript.evaluate(Predicate.new(:check, :custom_script, config: config), %{workspace: ws})
  end

  # Evaluate a ratchet recipe with a literal baseline and a metric that prints the
  # signal to stdout (the declared direction/allowed_regression drive the verdict).
  defp eval_ratchet(id, config, baseline, signal, ws) do
    config = %{config | baseline: baseline, metric: const(signal)}
    Ratchet.evaluate(Predicate.new(id, :ratchet, config: config), %{workspace: ws})
  end

  # A metric command that prints `n` to stdout (no JSON path).
  defp const(n), do: %{"cmd" => "sh", "args" => ["-c", "printf '%s' '#{n}'"]}

  # ===========================================================================
  # Contract / schema compat — DEMONSTRATION tier (fail directly)
  # ===========================================================================

  test "recipe_contract_buf.toml: a breaking proto change fails (exit code is the verdict)", %{
    workspace: ws
  } do
    {kind, _id, config} = recipe("recipe_contract_buf.toml")
    assert kind == :custom_script
    assert config.verdict == "exit_zero"

    # buf breaking exits non-zero ON a breaking change.
    assert eval_script(config, "Previously present field was deleted.", 1, ws).status == :fail
    assert eval_script(config, "", 0, ws).status == :pass
  end

  test "recipe_contract_oasdiff.toml: breaking OpenAPI change fails; undeclared code fails", %{
    workspace: ws
  } do
    {_kind, _id, config} = recipe("recipe_contract_oasdiff.toml")
    assert config.verdict == "exit_code"
    assert config.pass_codes == [0]
    assert config.fail_codes == [1]

    assert eval_script(config, "", 0, ws).status == :pass
    assert eval_script(config, "1 breaking changes", 1, ws).status == :fail
    # A gate never passes an undeclared code (oasdiff misbehaving).
    assert eval_script(config, "", 2, ws).status == :fail
  end

  test "recipe_contract_pact.toml: can-i-deploy false fails (exit code is the verdict)", %{
    workspace: ws
  } do
    {_kind, _id, config} = recipe("recipe_contract_pact.toml")
    assert config.verdict == "exit_zero"

    assert eval_script(config, "Computer says no", 1, ws).status == :fail
    assert eval_script(config, "Computer says yes", 0, ws).status == :pass
  end

  # ===========================================================================
  # Perf / size ratchets — PRESENCE/CLAIM tier (ratchet against a baseline)
  # ===========================================================================

  test "recipe_perf_ratchet.toml: a latency regression beyond budget trips the ratchet", %{
    workspace: ws
  } do
    {kind, id, config} = recipe("recipe_perf_ratchet.toml")
    assert kind == :ratchet
    assert config.direction == "lower_better"
    assert config.allowed_regression == 2.0

    # Baseline 10 ms, with the recipe's declared 2 ms budget.
    within = eval_ratchet(id, config, 10.0, 11.0, ws)
    assert within.status == :pass
    assert within.score == 11.0
    assert within.direction == :lower_better

    regressed = eval_ratchet(id, config, 10.0, 20.0, ws)
    assert regressed.status == :fail
    assert regressed.evidence.regression == 10.0
  end

  # ===========================================================================
  # Secret scanning — DEMONSTRATION tier, gated on PARSED output not exit code
  # ===========================================================================

  test "recipe_secret_trufflehog.toml: a verified secret fails even though the tool exits 0", %{
    workspace: ws
  } do
    {_kind, _id, config} = recipe("recipe_secret_trufflehog.toml")
    assert config.verdict == "match_count"
    assert config.pass_when == "== 0"

    verified = ~s({"DetectorName":"AWS","Verified":true})
    unverified = ~s({"DetectorName":"AWS","Verified":false})

    # TruffleHog exits 0 WITH findings — the recipe must still fail on a verified one.
    planted = eval_script(config, verified <> "\n" <> unverified, 0, ws)
    assert planted.status == :fail
    assert planted.evidence.observed == 1

    # Only unverified matches -> zero verified -> pass.
    assert eval_script(config, unverified, 0, ws).status == :pass
  end

  # ===========================================================================
  # Accessibility (Lighthouse) — PRESENCE/CLAIM tier (ratchet)
  # ===========================================================================

  test "recipe_a11y_lighthouse.toml: an a11y-score regression trips the ratchet", %{
    workspace: ws
  } do
    {kind, id, config} = recipe("recipe_a11y_lighthouse.toml")
    assert kind == :ratchet
    assert config.direction == "higher_better"
    assert config.allowed_regression == 0.0

    improved = eval_ratchet(id, config, 0.95, 0.96, ws)
    assert improved.status == :pass

    regressed = eval_ratchet(id, config, 0.95, 0.80, ws)
    assert regressed.status == :fail
  end

  # ===========================================================================
  # IaC / container scan — PRESENCE/CLAIM tier, gated on PARSED count not exit code
  # ===========================================================================

  test "recipe_iac_scan.toml: a new finding trips the ratchet, read from JSON not exit code", %{
    workspace: ws
  } do
    {kind, id, config} = recipe("recipe_iac_scan.toml")
    assert kind == :ratchet
    assert config.direction == "lower_better"
    assert config.metric["path"] == "$.Results[0].Misconfigurations"

    # The metric reads the misconfiguration COUNT off Trivy's JSON (a list path
    # yields its length). The fixture EXITS 0 with findings — the trivy exit-code
    # gotcha — so this proves the gate is on the parsed count, not the exit code.
    metric = fn n ->
      findings = List.duplicate("{}", n) |> Enum.join(",")
      json = ~s({"Results":[{"Misconfigurations":[#{findings}]}]})

      %{
        "cmd" => "sh",
        "args" => ["-c", "printf '%s' '#{json}'; exit 0"],
        "path" => "$.Results[0].Misconfigurations"
      }
    end

    evaluate = fn n ->
      cfg = %{config | baseline: 3, metric: metric.(n)}
      Ratchet.evaluate(Predicate.new(id, :ratchet, config: cfg), %{workspace: ws})
    end

    # 3 pre-existing findings == baseline -> no regression -> pass.
    at_baseline = evaluate.(3)
    assert at_baseline.status == :pass
    assert at_baseline.score == 3.0

    # A new (4th, 5th) finding -> a regression -> fail, despite the tool exiting 0.
    regressed = evaluate.(5)
    assert regressed.status == :fail
    assert regressed.evidence.regression == 2.0
  end

  # ===========================================================================
  # Visual regression — DEMONSTRATION tier (fail directly)
  # ===========================================================================

  test "recipe_visual_regression.toml: a pixel diff fails (exit code is the verdict)", %{
    workspace: ws
  } do
    {kind, _id, config} = recipe("recipe_visual_regression.toml")
    assert kind == :custom_script
    assert config.verdict == "exit_zero"

    assert eval_script(config, "Mismatch errors found.", 1, ws).status == :fail
    assert eval_script(config, "Passed.", 0, ws).status == :pass
  end
end

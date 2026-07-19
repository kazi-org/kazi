defmodule Kazi.Providers.CustomScriptExamplesTest do
  @moduledoc """
  T32.1 (ADR-0040) acceptance: the three shipped `custom_script` recipes under
  priv/examples/ both PARSE (load through the real loader, including the
  custom_script key validation) and EVALUATE — the declared verdict produces the
  right status against a representative envelope.

  The example `cmd`s name real tools that may not be installed here (semgrep,
  pytest, cargo), so each test loads the example's declared verdict/path/pass_when
  config, swaps only the `cmd`/`args` for a fixture that emits the envelope, and
  asserts the verdict — proving the DECLARATION the recipe ships is correct.
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader
  alias Kazi.Predicate
  alias Kazi.Providers.CustomScript

  @examples Path.join([File.cwd!(), "priv", "examples"])

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_cs_examples_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  # Load the single custom_script predicate config from an example file.
  defp example_config(name) do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :custom_script, config: config}]}} =
             Loader.load(Path.join(@examples, name))

    config
  end

  # Evaluate the example's declared verdict, with cmd/args swapped to a fixture
  # that prints `out` and exits `code`.
  defp evaluate_with(config, out, code, ws) do
    config =
      Map.merge(config, %{cmd: "sh", args: ["-c", "printf '%s' '#{out}'; exit #{code}"]})

    CustomScript.evaluate(Predicate.new(:check, :custom_script, config: config), %{workspace: ws})
  end

  test "custom_script_sarif.toml: findings -> :fail, none -> :pass", %{workspace: ws} do
    config = example_config("custom_script_sarif.toml")
    assert config.verdict == "json"
    assert config.pass_when == "== 0"

    findings = ~s({"runs":[{"results":[{"ruleId":"r1"}]}]})
    none = ~s({"runs":[{"results":[]}]})

    # Semgrep exits 0 even WITH findings — the recipe must still fail.
    assert evaluate_with(config, findings, 0, ws).status == :fail
    assert evaluate_with(config, none, 0, ws).status == :pass
  end

  test "custom_script_junit.toml: exit code is the verdict, JUnit is evidence", %{workspace: ws} do
    config = example_config("custom_script_junit.toml")
    assert config.verdict == "exit_zero"
    assert config.evidence_format == "junit"

    xml = ~s(<testsuite><testcase name="bad"><failure message="x"/></testcase></testsuite>)

    pass = evaluate_with(config, xml, 0, ws)
    fail = evaluate_with(config, xml, 1, ws)

    assert pass.status == :pass
    assert fail.status == :fail
    assert [%{case: "bad"}] = fail.evidence.findings
  end

  test "custom_script_mutation.toml: score >= 80 -> :pass, below -> :fail", %{workspace: ws} do
    config = example_config("custom_script_mutation.toml")
    assert config.verdict == "json"
    assert config.pass_when == ">= 80"

    assert evaluate_with(config, ~s({"mutation_score":85}), 0, ws).status == :pass
    assert evaluate_with(config, ~s({"mutation_score":40}), 0, ws).status == :fail
  end
end

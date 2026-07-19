defmodule Kazi.Goal.DeferredSurfaceRecipesTest do
  @moduledoc """
  T43.10 (ADR-0053 §3) acceptance: the deferred-surface `custom_script` recipes
  under priv/examples/deferred_surface_recipes/ both PARSE (load through the real
  loader, including custom_script key validation) and carry the CORRECT verdict
  declaration for their tool's real exit-code / output contract.

  The example `cmd`s name external tools that are not installed in CI (maestro,
  oasdiff, schemathesis, lighthouse), so — as in CustomScriptExamplesTest — each
  test loads the recipe's declared verdict/keys and swaps only the `cmd`/`args` for
  a fixture that emits the tool's real envelope, then asserts the verdict. The
  Lighthouse budget gate is exercised against the REAL committed Lighthouse-shaped
  report fixtures. (The real tools themselves are exercised out-of-band; see the
  recipe READMEs and the PR body for which were run live.)
  """
  use ExUnit.Case, async: true

  alias Kazi.Goal
  alias Kazi.Goal.Loader
  alias Kazi.Predicate
  alias Kazi.Providers.CustomScript

  @recipes Path.join([File.cwd!(), "priv", "examples", "deferred_surface_recipes"])

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_deferred_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  defp recipe_config(rel) do
    assert {:ok, %Goal{predicates: [%Predicate{kind: :custom_script, config: config}]}} =
             Loader.load(Path.join(@recipes, rel))

    config
  end

  # Evaluate the recipe's declared verdict with cmd/args swapped to a fixture that
  # prints `out` and exits `code` — proving the DECLARATION the recipe ships maps
  # the tool's real exit/output to the right status.
  defp evaluate_with(config, out, code, ws) do
    config = Map.merge(config, %{cmd: "sh", args: ["-c", "printf '%s' '#{out}'; exit #{code}"]})
    CustomScript.evaluate(Predicate.new(:check, :custom_script, config: config), %{workspace: ws})
  end

  test "mobile/recipe.goal.toml: exit_zero — a failing Maestro flow fails", %{workspace: ws} do
    config = recipe_config("mobile/recipe.goal.toml")
    assert config.verdict == "exit_zero"
    assert config.cmd == "maestro"

    assert evaluate_with(config, "Flow passed", 0, ws).status == :pass
    assert evaluate_with(config, "Assertion failed", 1, ws).status == :fail
  end

  test "tui/recipe.goal.toml: exit_zero — a failed expect assertion fails", %{workspace: ws} do
    config = recipe_config("tui/recipe.goal.toml")
    assert config.verdict == "exit_zero"
    assert config.cmd == "expect"

    assert evaluate_with(config, "ok", 0, ws).status == :pass
    assert evaluate_with(config, "FAIL: wrong add result", 1, ws).status == :fail
  end

  test "api_contract/recipe.oasdiff: exit_code — a breaking diff (exit 1) fails", %{workspace: ws} do
    config = recipe_config("api_contract/recipe.oasdiff.goal.toml")
    assert config.verdict == "exit_code"
    assert config.pass_codes == [0]
    assert config.fail_codes == [1]

    assert evaluate_with(config, "No breaking changes", 0, ws).status == :pass
    assert evaluate_with(config, "2 breaking changes", 1, ws).status == :fail
    # A gate never passes an undeclared code (oasdiff misbehaving).
    assert evaluate_with(config, "panic", 2, ws).status == :fail
  end

  test "api_contract/recipe.schemathesis: exit_zero, infra codes are :error", %{workspace: ws} do
    config = recipe_config("api_contract/recipe.schemathesis.goal.toml")
    assert config.verdict == "exit_zero"
    assert config.error_codes == [2, 3]

    assert evaluate_with(config, "1 passed", 0, ws).status == :pass
    assert evaluate_with(config, "1 failed", 1, ws).status == :fail
    # An unreachable fixture server / bad spec is infra, not failing API work.
    assert evaluate_with(config, "connection refused", 2, ws).status == :error
  end

  test "lighthouse/recipe.goal.toml: json budget gate over REAL report fixtures" do
    config = recipe_config("lighthouse/recipe.goal.toml")
    assert config.verdict == "json"
    assert config.path == "$.categories.performance.score"
    assert config.pass_when == ">= 0.9"

    ws = Path.join(@recipes, "lighthouse")

    low = evaluate(config, "report.lowscore.json", ws)
    good = evaluate(config, "report.goodscore.json", ws)

    # score 0.42 is under the 0.9 budget -> the recipe FAILS.
    assert low.status == :fail
    assert low.evidence.observed == 0.42
    # score 0.95 clears the budget -> PASS.
    assert good.status == :pass
    assert good.evidence.observed == 0.95
  end

  # Feed a committed Lighthouse report to the recipe's real json verdict via `cat`,
  # so the gate reads the actual report shape, not a hand-built envelope.
  defp evaluate(config, report, ws) do
    config = Map.merge(config, %{cmd: "cat", args: [report]})
    CustomScript.evaluate(Predicate.new(:check, :custom_script, config: config), %{workspace: ws})
  end
end

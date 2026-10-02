defmodule Kazi.Teach.AuthoringVitestPatternTest do
  use ExUnit.Case, async: false

  alias Kazi.Teach.InstallSkill
  alias Kazi.Providers.CustomScript

  @fixture Path.expand("../../fixtures/vitest_authoring_pattern", __DIR__)
  @test_name "passes the target case"
  @match_regex "^\\s*✓ .* > passes the target case(?: \\(\\d+(?:\\.\\d+)?ms\\))?$"
  @moduletag timeout: 300_000
  @matcher_predicate %{
    cmd: "npx",
    args: ["--no-install", "vitest", "run", "-t", @test_name, "--reporter=verbose"],
    verdict: "match_count",
    match_regex: @match_regex,
    pass_when: ">= 1"
  }
  @exit_predicate %{
    cmd: "npx",
    args: ["--no-install", "vitest", "run", "-t", @test_name, "--reporter=verbose"],
    verdict: "exit_zero"
  }
  @toml_atom_keys %{
    "id" => :id,
    "provider" => :provider,
    "description" => :description,
    "cmd" => :cmd,
    "env" => :env,
    "args" => :args,
    "verdict" => :verdict,
    "match_regex" => :match_regex,
    "pass_when" => :pass_when
  }

  test "the paired documented predicates reject selected Vitest test failures" do
    task_tmp = Path.join(File.cwd!(), "tmp/vitest-authoring-cache")
    File.mkdir_p!(task_tmp)

    npm_env = [
      {"TMPDIR", task_tmp},
      {"npm_config_cache", Path.join(task_tmp, "npm-cache")}
    ]

    {_npm_output, 0} =
      System.cmd("npm", ["ci", "--ignore-scripts", "--no-audit", "--no-fund"],
        cd: @fixture,
        env: npm_env,
        stderr_to_stdout: true
      )

    authoring = InstallSkill.authoring_md()

    toml =
      authoring
      |> String.split("```toml")
      |> Enum.find(&String.contains?(&1, "vitest-target-passing-line"))
      |> case do
        nil -> flunk("AUTHORING.md must include the paired Vitest predicates")
        chunk -> chunk |> String.split("```", parts: 2) |> hd()
      end

    assert {:ok, %{"predicate" => [decoded_matcher, decoded_exit]}} = Toml.decode(toml)
    matcher_predicate = atomize_config(decoded_matcher)
    exit_predicate = atomize_config(decoded_exit)

    assert matcher_predicate[:id] == "vitest-target-passing-line"
    assert matcher_predicate[:provider] == "custom_script"
    assert matcher_predicate[:args] == @matcher_predicate[:args]
    assert matcher_predicate[:match_regex] == @match_regex
    assert matcher_predicate[:pass_when] == ">= 1"
    assert exit_predicate[:id] == "vitest-selected-tests-exit-zero"
    assert exit_predicate[:provider] == "custom_script"
    assert exit_predicate[:cmd] == matcher_predicate[:cmd]
    assert exit_predicate[:args] == @exit_predicate[:args]
    assert exit_predicate[:args] == matcher_predicate[:args]
    assert exit_predicate[:verdict] == "exit_zero"

    assert matcher_predicate[:env] == %{"NO_COLOR" => "1", "FORCE_COLOR" => "0"}
    assert exit_predicate[:env] == matcher_predicate[:env]

    matcher_predicate =
      Map.update!(matcher_predicate, :env, &Map.merge(Map.new(npm_env), &1))

    exit_predicate = Map.update!(exit_predicate, :env, &Map.merge(Map.new(npm_env), &1))

    passing_matcher = CustomScript.evaluate_config(matcher_predicate, %{workspace: @fixture})
    passing_exit = CustomScript.evaluate_config(exit_predicate, %{workspace: @fixture})

    assert passing_matcher.status == :pass, inspect(passing_matcher.evidence)
    assert passing_matcher.evidence.observed == 1
    assert passing_exit.status == :pass
    assert passing_exit.evidence.output =~ ~r/Tests\s+1 passed \| 2 skipped \(3\)/
    refute passing_exit.evidence.output =~ ~r/Tests\s+1 passed \(1\)/

    failing_workspace =
      Path.join(File.cwd!(), "tmp/vitest-negative-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.dirname(failing_workspace))
    File.cp_r!(@fixture, failing_workspace)
    on_exit(fn -> File.rm_rf!(failing_workspace) end)

    target_spec = Path.join(failing_workspace, "specs/target.spec.js")
    File.write!(target_spec, String.replace(File.read!(target_spec), "toBe(2)", "toBe(3)"))

    failing_matcher =
      CustomScript.evaluate_config(matcher_predicate, %{workspace: failing_workspace})

    failing_exit = CustomScript.evaluate_config(exit_predicate, %{workspace: failing_workspace})

    assert failing_matcher.status == :fail
    assert failing_matcher.evidence.observed == 0
    assert failing_exit.status == :fail
    assert failing_exit.evidence.output =~ ~r/Tests\s+1 failed \| 2 skipped \(3\)/

    other_failure_workspace =
      Path.join(File.cwd!(), "tmp/vitest-other-failure-#{System.unique_integer([:positive])}")

    File.cp_r!(@fixture, other_failure_workspace)
    on_exit(fn -> File.rm_rf!(other_failure_workspace) end)

    other_spec = Path.join(other_failure_workspace, "specs/other.spec.js")

    File.write!(
      other_spec,
      File.read!(other_spec) <>
        "\ntest(\"passes the target case but sibling fails\", () => {\n" <>
        "  expect(true).toBe(false);\n});\n"
    )

    other_matcher =
      CustomScript.evaluate_config(matcher_predicate, %{workspace: other_failure_workspace})

    other_exit =
      CustomScript.evaluate_config(exit_predicate, %{workspace: other_failure_workspace})

    assert other_matcher.status == :pass
    assert other_matcher.evidence.observed == 1
    assert other_exit.status == :fail
    assert other_exit.evidence.output =~ ~r/Tests\s+.*\b1 passed\b/
    assert other_exit.evidence.output =~ ~r/Tests\s+.*\b1 failed\b/
    assert other_exit.evidence.output =~ ~r/2 skipped \(4\)/

    absent_workspace =
      Path.join(File.cwd!(), "tmp/vitest-absent-target-#{System.unique_integer([:positive])}")

    File.cp_r!(@fixture, absent_workspace)
    on_exit(fn -> File.rm_rf!(absent_workspace) end)
    absent_spec = Path.join(absent_workspace, "specs/target.spec.js")

    File.write!(
      absent_spec,
      String.replace(File.read!(absent_spec), @test_name, @test_name <> " but renamed")
    )

    absent_matcher =
      CustomScript.evaluate_config(matcher_predicate, %{workspace: absent_workspace})

    absent_exit = CustomScript.evaluate_config(exit_predicate, %{workspace: absent_workspace})

    assert absent_matcher.status == :fail
    assert absent_matcher.evidence.observed == 0
    assert absent_exit.status == :pass
  end

  defp atomize_config(config) do
    Map.new(config, fn {key, value} -> {Map.fetch!(@toml_atom_keys, key), value} end)
  end
end

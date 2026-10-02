defmodule Kazi.Teach.AuthoringVitestPatternTest do
  use ExUnit.Case, async: false

  alias Kazi.Teach.InstallSkill
  alias Kazi.Providers.CustomScript

  @fixture Path.expand("../../fixtures/vitest_authoring_pattern", __DIR__)
  @test_name "passes the target case"
  @match_regex "✓ .* > passes the target case"
  @moduletag timeout: 300_000
  @predicate %{
    cmd: "npx",
    args: ["--no-install", "vitest", "run", "-t", @test_name, "--reporter=verbose"],
    verdict: "match_count",
    match_regex: @match_regex,
    pass_when: ">= 1"
  }

  test "the documented per-test matcher passes on a multi-spec Vitest project" do
    task_tmp = Path.join(File.cwd!(), "tmp/vitest-authoring-cache")
    File.mkdir_p!(task_tmp)

    npm_env = [
      {"TMPDIR", task_tmp},
      {"npm_config_cache", Path.join(task_tmp, "npm-cache")}
    ]

    {npm_output, 0} =
      System.cmd("npm", ["ci", "--ignore-scripts", "--no-audit", "--no-fund"],
        cd: @fixture,
        env: npm_env,
        stderr_to_stdout: true
      )

    authoring = InstallSkill.authoring_md()

    assert authoring =~ ~s(match_regex = "#{@match_regex}")
    assert authoring =~ ~s(pass_when = ">= 1")

    assert authoring =~
             ~s(args = ["--no-install", "vitest", "run", "-t", "passes the target case", "--reporter=verbose"])

    assert is_binary(npm_output)

    predicate = Map.put(@predicate, :env, Map.new(npm_env))

    passing = CustomScript.evaluate_config(predicate, %{workspace: @fixture})

    assert passing.status == :pass
    assert passing.evidence.observed == 1
    assert passing.evidence.output =~ ~r/Tests\s+1 passed \| 2 skipped \(3\)/
    refute passing.evidence.output =~ ~r/Tests\s+1 passed \(1\)/

    failing_workspace =
      Path.join(File.cwd!(), "tmp/vitest-negative-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.dirname(failing_workspace))
    File.cp_r!(@fixture, failing_workspace)
    on_exit(fn -> File.rm_rf!(failing_workspace) end)

    target_spec = Path.join(failing_workspace, "specs/target.spec.js")
    File.write!(target_spec, String.replace(File.read!(target_spec), "toBe(2)", "toBe(3)"))

    failing = CustomScript.evaluate_config(predicate, %{workspace: failing_workspace})

    assert failing.status == :fail
    assert failing.evidence.observed == 0
    assert failing.evidence.output =~ ~r/Tests\s+1 failed \| 2 skipped \(3\)/
  end
end

defmodule Kazi.Providers.CustomScriptTest do
  # Tier 2: real boundary. These run actual commands via System.cmd in a temp
  # workspace and assert the resulting PredicateResult, proving the generic
  # command-runner maps real exit codes + stdout to the DECLARED verdict
  # (T32.1, ADR-0040).
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.CustomScript

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_custom_script_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  defp predicate(config), do: Predicate.new(:check, :custom_script, config: config)

  defp evaluate(config, ws), do: CustomScript.evaluate(predicate(config), %{workspace: ws})

  # A command that prints `out` to stdout and exits `code`.
  defp emit(out, code), do: %{cmd: "sh", args: ["-c", "printf '%s' '#{out}'; exit #{code}"]}

  test "implements the PredicateProvider behaviour" do
    behaviours = CustomScript.module_info(:attributes)[:behaviour] || []
    assert Kazi.PredicateProvider in behaviours
  end

  describe "exit_zero verdict (default)" do
    test "exit 0 -> :pass with verdict + exit in evidence", %{workspace: ws} do
      result = evaluate(%{cmd: "sh", args: ["-c", "exit 0"]}, ws)
      assert %PredicateResult{status: :pass} = result
      assert result.evidence.exit == 0
      assert result.evidence.verdict == "exit_zero"
    end

    test "non-zero exit -> :fail (not :error)", %{workspace: ws} do
      result = evaluate(%{cmd: "sh", args: ["-c", "exit 1"]}, ws)
      assert result.status == :fail
      assert result.evidence.exit == 1
    end

    test "is the default when no verdict is declared", %{workspace: ws} do
      assert evaluate(%{cmd: "sh", args: ["-c", "exit 0"]}, ws).status == :pass
    end
  end

  describe "exit_code verdict" do
    test "a declared pass code -> :pass", %{workspace: ws} do
      config = %{cmd: "sh", args: ["-c", "exit 2"], verdict: "exit_code", pass_codes: [2]}
      assert evaluate(config, ws).status == :pass
    end

    test "a declared fail code -> :fail", %{workspace: ws} do
      config = %{
        cmd: "sh",
        args: ["-c", "exit 3"],
        verdict: "exit_code",
        pass_codes: [0],
        fail_codes: [3]
      }

      assert evaluate(config, ws).status == :fail
    end

    test "an undeclared code -> :fail (a gate never passes an undeclared code)", %{workspace: ws} do
      config = %{cmd: "sh", args: ["-c", "exit 7"], verdict: "exit_code", pass_codes: [0]}
      result = evaluate(config, ws)
      assert result.status == :fail
      assert result.evidence.unmatched_code == true
    end
  end

  describe "json verdict" do
    test "a SARIF-style tool exiting 0 WITH findings -> :fail (the keystone)", %{workspace: ws} do
      # Exit 0 but the parsed findings array is non-empty: gated on the count.
      sarif = ~s({"runs":[{"results":[{"ruleId":"r1"},{"ruleId":"r2"}]}]})

      config =
        Map.merge(emit(sarif, 0), %{verdict: "json", path: "$.runs[0].results", pass_when: "== 0"})

      result = evaluate(config, ws)
      assert result.status == :fail
      assert result.evidence.observed == 2
      assert result.evidence.path == "$.runs[0].results"
    end

    test "zero findings (empty array) -> :pass", %{workspace: ws} do
      config =
        Map.merge(emit(~s({"runs":[{"results":[]}]}), 0), %{
          verdict: "json",
          path: "$.runs[0].results",
          pass_when: "== 0"
        })

      assert evaluate(config, ws).status == :pass
    end

    test "a scalar score compared with >= -> :pass / :fail", %{workspace: ws} do
      pass =
        Map.merge(emit(~s({"mutation_score":92}), 0), %{
          verdict: "json",
          path: "$.mutation_score",
          pass_when: ">= 80"
        })

      fail = put_in(pass.args, ["-c", "printf '%s' '{\"mutation_score\":61}'; exit 0"])

      assert evaluate(pass, ws).status == :pass
      assert evaluate(fail, ws).status == :fail
    end

    test "invalid JSON on stdout -> :error (never a silent pass)", %{workspace: ws} do
      config =
        Map.merge(emit("not json at all", 0), %{
          verdict: "json",
          path: "$.x",
          pass_when: "== 0"
        })

      result = evaluate(config, ws)
      assert result.status == :error
      assert result.evidence.reason == :invalid_json_output
    end

    test "a path that does not resolve -> :error", %{workspace: ws} do
      config =
        Map.merge(emit(~s({"a":1}), 0), %{verdict: "json", path: "$.missing", pass_when: "== 0"})

      result = evaluate(config, ws)
      assert result.status == :error
      assert match?({:path_missing, "missing", _}, result.evidence.reason)
    end
  end

  describe ":error vs :fail" do
    test "a missing binary -> :error, NOT :fail", %{workspace: ws} do
      config = %{cmd: "kazi_no_such_binary_#{System.unique_integer([:positive])}"}
      result = evaluate(config, ws)
      assert result.status == :error
      assert match?({:cmd_unrunnable, _}, result.evidence.reason)
    end

    test "a declared error_code exit -> :error, NOT :fail", %{workspace: ws} do
      config = %{cmd: "sh", args: ["-c", "exit 2"], error_codes: [2]}
      result = evaluate(config, ws)
      assert result.status == :error
      assert result.evidence.reason == {:error_exit, 2}
    end

    test "error_codes are checked before the verdict (an error code never becomes a pass)",
         %{workspace: ws} do
      # exit_code maps 2 -> pass, but error_codes claims 2 -> could-not-run. Error wins.
      config = %{
        cmd: "sh",
        args: ["-c", "exit 2"],
        verdict: "exit_code",
        pass_codes: [2],
        error_codes: [2]
      }

      assert evaluate(config, ws).status == :error
    end

    test "absent :cmd -> :error, not a crash", %{workspace: ws} do
      result = evaluate(%{}, ws)
      assert result.status == :error
      assert result.evidence.reason == :missing_cmd
    end

    test "an unknown verdict -> :error", %{workspace: ws} do
      result = evaluate(%{cmd: "sh", args: ["-c", "exit 0"], verdict: "guess"}, ws)
      assert result.status == :error
      assert result.evidence.reason == {:unknown_verdict, "guess"}
    end

    test "a non-:custom_script kind -> :error" do
      result = CustomScript.evaluate(Predicate.new(:probe, :http_probe), %{})
      assert result.status == :error
      assert match?({:unsupported_kind, :http_probe}, result.evidence.reason)
    end
  end

  describe "timeout_ms" do
    test "a command that overruns the timeout -> :error", %{workspace: ws} do
      config = %{cmd: "sh", args: ["-c", "sleep 5"], timeout_ms: 100}
      result = evaluate(config, ws)
      assert result.status == :error
      assert result.evidence.reason == {:timeout_ms, 100}
    end

    test "a command that finishes within the timeout is unaffected", %{workspace: ws} do
      config = %{cmd: "sh", args: ["-c", "exit 0"], timeout_ms: 5_000}
      assert evaluate(config, ws).status == :pass
    end
  end

  describe "evidence_format" do
    test "sarif extracts structured findings", %{workspace: ws} do
      sarif =
        ~s({"runs":[{"results":[{"ruleId":"no-eval","level":"error",) <>
          ~s("message":{"text":"eval is bad"},"locations":[{"physicalLocation":) <>
          ~s({"artifactLocation":{"uri":"app.py"},"region":{"startLine":12}}}]}]}]})

      config =
        Map.merge(emit(sarif, 0), %{
          verdict: "json",
          evidence_format: "sarif",
          path: "$.runs[0].results",
          pass_when: "== 0"
        })

      result = evaluate(config, ws)
      assert result.status == :fail
      assert [finding] = result.evidence.findings
      assert finding.rule == "no-eval"
      assert finding.file == "app.py"
      assert finding.line == 12
      assert finding.message == "eval is bad"
    end

    test "junit extracts failing cases from stdout XML", %{workspace: ws} do
      xml =
        ~s(<testsuite><testcase name="ok_one"/>) <>
          ~s(<testcase name="bad_two"><failure message="boom">trace</failure></testcase>) <>
          ~s(</testsuite>)

      config = Map.merge(emit(xml, 1), %{evidence_format: "junit"})
      result = evaluate(config, ws)
      assert result.status == :fail
      assert [finding] = result.evidence.findings
      assert finding.case == "bad_two"
      assert finding.kind == "failure"
      assert finding.message == "boom"
    end
  end

  test "runs the command in the target workspace", %{workspace: ws} do
    File.write!(Path.join(ws, "marker.txt"), "here")
    config = %{cmd: "sh", args: ["-c", "test -f marker.txt"]}
    assert evaluate(config, ws).status == :pass
  end

  test "defaults workspace to cwd when context omits it" do
    result = CustomScript.evaluate(predicate(%{cmd: "sh", args: ["-c", "exit 0"]}), %{})
    assert result.status == :pass
    assert result.evidence.workspace == File.cwd!()
  end
end

defmodule Kazi.Providers.SwiftTestProviderTest do
  # Real boundary: these run a command that emits a RECORDED `xcresulttool get
  # test-results summary` JSON payload and assert the resulting PredicateResult,
  # proving the :swift_test provider reads the PARSED pass/fail/zero-tests counts
  # from an .xcresult summary (never the exit code) — no live Xcode/xcresulttool
  # needed (issue #1406).
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.SwiftTest

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_swift_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  defp evaluate(config, ws),
    do: SwiftTest.evaluate(Predicate.new(:swift, :swift_test, config: config), %{workspace: ws})

  defp script(payload) do
    json = Jason.encode!(payload)
    ["-c", "printf '%s' '#{json}'"]
  end

  test "implements the PredicateProvider behaviour" do
    behaviours = SwiftTest.module_info(:attributes)[:behaviour] || []
    assert Kazi.PredicateProvider in behaviours
  end

  describe "reading the xcresulttool summary" do
    @passing %{
      "totalTestCount" => 6,
      "passedTests" => 6,
      "failedTests" => 0,
      "skippedTests" => 0,
      "expectedFailures" => 0,
      "result" => "Passed",
      "testFailures" => []
    }

    test "all tests passed -> :pass with the passed-test score", %{workspace: ws} do
      config = %{cmd: "sh", args: script(@passing), xcresult_path: "TestResults.xcresult"}

      result = evaluate(config, ws)
      assert %PredicateResult{status: :pass} = result
      assert result.score == 6.0
      assert result.direction == :higher_better
      assert result.evidence.total_tests == 6
      assert result.evidence.passed_tests == 6
      assert result.evidence.failed_tests == 0
      assert result.evidence.xcresult_path == "TestResults.xcresult"
    end

    @failing %{
      "totalTestCount" => 6,
      "passedTests" => 4,
      "failedTests" => 2,
      "skippedTests" => 0,
      "expectedFailures" => 0,
      "result" => "Failed",
      "testFailures" => [
        %{"testIdentifierString" => "AppTests/testA", "failureText" => "XCTAssertEqual failed"},
        %{"testIdentifierString" => "AppTests/testB", "failureText" => "timed out"}
      ]
    }

    test "xcresulttool exits 0 EVEN WITH failing tests -> gated on parsed counts, not exit",
         %{workspace: ws} do
      [flag, script] = script(@failing)

      config = %{
        cmd: "sh",
        args: [flag, script <> "; exit 0"],
        xcresult_path: "TestResults.xcresult"
      }

      result = evaluate(config, ws)
      assert result.status == :fail
      assert result.score == 4.0
      assert result.evidence.failed_tests == 2
      assert length(result.evidence.failures) == 2
      assert [diag1, diag2] = result.diagnostics
      assert diag1.rule == "AppTests/testA"
      assert diag1.message == "XCTAssertEqual failed"
      assert diag2.rule == "AppTests/testB"
    end

    @zero %{
      "totalTestCount" => 0,
      "passedTests" => 0,
      "failedTests" => 0,
      "skippedTests" => 0,
      "expectedFailures" => 0,
      "result" => "Passed",
      "testFailures" => []
    }

    test "zero tests run -> :fail (broken scheme, not a green suite)", %{workspace: ws} do
      config = %{cmd: "sh", args: script(@zero), xcresult_path: "TestResults.xcresult"}

      result = evaluate(config, ws)
      assert result.status == :fail
      assert result.evidence.reason == :zero_tests
      assert result.evidence.total_tests == 0
    end

    test "a summary missing the count fields is :unknown, never a guessed pass", %{
      workspace: ws
    } do
      config = %{
        cmd: "sh",
        args: script(%{"result" => "Passed"}),
        xcresult_path: "TestResults.xcresult"
      }

      result = evaluate(config, ws)
      assert result.status == :unknown
      assert result.evidence.reason == :unrecognized_summary_schema
    end
  end

  describe "config errors" do
    test "a missing xcresult_path is :error, not a dispatch against nothing", %{workspace: ws} do
      result = evaluate(%{cmd: "sh", args: ["-c", "true"]}, ws)
      assert result.status == :error
      assert result.evidence.reason == :missing_xcresult_path
    end
  end

  describe "error boundary" do
    test "invalid JSON output is :error, not a silent pass", %{workspace: ws} do
      config = %{
        cmd: "sh",
        args: ["-c", "printf 'not json'; exit 1"],
        xcresult_path: "TestResults.xcresult"
      }

      assert evaluate(config, ws).status == :error
    end

    test "a missing binary is :error", %{workspace: ws} do
      config = %{cmd: "definitely-not-a-real-binary-xyz", xcresult_path: "TestResults.xcresult"}
      assert evaluate(config, ws).status == :error
    end
  end

  test "an unsupported kind is an :error" do
    result = SwiftTest.evaluate(%Predicate{id: :x, kind: :tests, config: %{}}, %{})
    assert result.status == :error
  end
end

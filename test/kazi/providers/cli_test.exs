defmodule Kazi.Providers.CliTest do
  @moduledoc """
  T43.7 (UC-055): the `:cli` provider runs a shipped binary and gates on the exit
  code + stdout/stderr. These tests are the REAL boundary — they shell out to real
  POSIX binaries (`sh`, via `echo`/redirect/`exit`) through the real
  `Kazi.Providers.CommandRunner`, never a mock — so they prove the provider reads
  the true observable surface: a violated assertion is a `:fail` with expected-vs-
  found evidence, an unlaunchable `cmd` is an `:error` (never `:fail`), and the two
  streams are asserted independently.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.Cli

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_cli_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  # Stub the command with a real shell script: `sh -c "<script>"`. The provider
  # itself resolves `sh` and re-wraps it, but the observable stdout/stderr/exit are
  # exactly what the script produces — a real command-execution boundary.
  defp sh(script), do: %{cmd: "sh", args: ["-c", script]}

  defp evaluate(config, ws),
    do: Cli.evaluate(Predicate.new(:cli, :cli, config: config), %{workspace: ws})

  describe "verdict" do
    test "all assertions satisfied -> :pass with score = assertions passed", %{workspace: ws} do
      config =
        Map.merge(sh("echo kazi-1.2.3; exit 0"), %{
          assertions: [
            %{"target" => "exit_code", "expected" => 0},
            %{"target" => "stdout", "match" => "contains", "expected" => "kazi"},
            %{"target" => "stdout", "match" => "regex", "expected" => "\\d+\\.\\d+\\.\\d+"}
          ]
        })

      assert %PredicateResult{status: :pass, score: 3.0, direction: :higher_better} =
               result = evaluate(config, ws)

      assert result.evidence.passed == 3
      assert result.evidence.total == 3
    end

    test "a violated assertion is :fail with expected-vs-found evidence", %{workspace: ws} do
      config =
        Map.merge(sh("echo hi; exit 2"), %{
          assertions: [
            %{"target" => "exit_code", "expected" => 0},
            %{"target" => "stdout", "match" => "contains", "expected" => "hi"}
          ]
        })

      assert %PredicateResult{status: :fail, score: 1.0, direction: :higher_better} =
               result = evaluate(config, ws)

      assert [failure] = result.evidence.assertion_failures
      assert failure.target == "exit_code"
      assert failure.expected == 0
      assert failure.found == 2
    end

    test "an unrunnable cmd is :error, never :fail", %{workspace: ws} do
      config = %{
        cmd: "kazi-definitely-not-a-real-binary-xyz",
        args: [],
        assertions: [%{"target" => "exit_code", "expected" => 0}]
      }

      assert %PredicateResult{status: :error} = result = evaluate(config, ws)

      assert {:cmd_unrunnable, {:not_found, "kazi-definitely-not-a-real-binary-xyz"}} =
               result.evidence.reason
    end

    test "a timeout is :error, never :fail", %{workspace: ws} do
      config =
        Map.merge(sh("sleep 5; echo done"), %{
          timeout_ms: 100,
          assertions: [%{"target" => "exit_code", "expected" => 0}]
        })

      assert %PredicateResult{status: :error} = result = evaluate(config, ws)
      assert {:timeout_ms, 100} = result.evidence.reason
    end
  end

  describe "stdout / stderr are independent" do
    test "stderr is captured separately from stdout", %{workspace: ws} do
      config =
        Map.merge(sh("echo out; echo boom >&2; exit 0"), %{
          assertions: [
            %{"target" => "stdout", "match" => "equals", "expected" => "out\n"},
            %{"target" => "stderr", "match" => "contains", "expected" => "boom"}
          ]
        })

      assert %PredicateResult{status: :pass} = result = evaluate(config, ws)
      assert result.evidence.stdout == "out\n"
      assert result.evidence.stderr =~ "boom"
    end

    test "a clean stderr (`stderr equals \"\"`) passes; noise fails it", %{workspace: ws} do
      clean =
        Map.merge(sh("echo ok; exit 0"), %{
          assertions: [%{"target" => "stderr", "match" => "equals", "expected" => ""}]
        })

      noisy =
        Map.merge(sh("echo warning >&2; exit 0"), %{
          assertions: [%{"target" => "stderr", "match" => "equals", "expected" => ""}]
        })

      assert %PredicateResult{status: :pass} = evaluate(clean, ws)
      assert %PredicateResult{status: :fail} = evaluate(noisy, ws)
    end
  end

  describe "matchers" do
    test "equals is whole-stream equality", %{workspace: ws} do
      exact =
        Map.merge(sh("printf hello"), %{
          assertions: [%{"target" => "stdout", "match" => "equals", "expected" => "hello"}]
        })

      partial =
        Map.merge(sh("printf hello-world"), %{
          assertions: [%{"target" => "stdout", "match" => "equals", "expected" => "hello"}]
        })

      assert %PredicateResult{status: :pass} = evaluate(exact, ws)
      assert %PredicateResult{status: :fail} = evaluate(partial, ws)
    end

    test "json_path extracts and compares a value from parsed stdout", %{workspace: ws} do
      config =
        Map.merge(sh(~s|echo '{"schema_version": 2, "kazi": "9.9.9"}'|), %{
          assertions: [
            %{
              "target" => "stdout",
              "match" => "json_path",
              "path" => "$.schema_version",
              "expected" => 2
            }
          ]
        })

      assert %PredicateResult{status: :pass} = result = evaluate(config, ws)
      assert [res] = result.evidence.results
      assert res.extracted == 2
    end

    test "json_path over non-JSON output is a :fail (binary ran), not an :error",
         %{workspace: ws} do
      config =
        Map.merge(sh("echo not-json; exit 0"), %{
          assertions: [
            %{"target" => "stdout", "match" => "json_path", "path" => "$.x", "expected" => 1}
          ]
        })

      assert %PredicateResult{status: :fail} = result = evaluate(config, ws)
      assert [failure] = result.evidence.assertion_failures
      assert failure.reason == :invalid_json_output
    end

    test "golden: whole-stream match against a committed file passes", %{workspace: ws} do
      File.write!(Path.join(ws, "help.golden"), "usage: kazi\n")

      config =
        Map.merge(sh(~s|printf 'usage: kazi\\n'|), %{
          assertions: [%{"target" => "stdout", "match" => "golden", "golden" => "help.golden"}]
        })

      assert %PredicateResult{status: :pass} = result = evaluate(config, ws)
      assert [res] = result.evidence.results
      assert res.golden == "help.golden"
    end

    test "golden: a mismatch is :fail carrying a unified diff", %{workspace: ws} do
      File.write!(Path.join(ws, "help.golden"), "usage: kazi [command]\n")

      config =
        Map.merge(sh(~s|printf 'usage: kazi\\n'|), %{
          assertions: [%{"target" => "stdout", "match" => "golden", "golden" => "help.golden"}]
        })

      assert %PredicateResult{status: :fail} = result = evaluate(config, ws)
      assert [failure] = result.evidence.assertion_failures
      # The diff shows the golden line removed (-) and the actual output added (+).
      assert failure.diff =~ "- usage: kazi [command]"
      assert failure.diff =~ "+ usage: kazi"
    end

    test "golden: a missing golden file is :fail naming the path (binary ran)", %{workspace: ws} do
      config =
        Map.merge(sh("printf hi"), %{
          assertions: [%{"target" => "stdout", "match" => "golden", "golden" => "absent.golden"}]
        })

      assert %PredicateResult{status: :fail} = result = evaluate(config, ws)
      assert [failure] = result.evidence.assertion_failures
      assert failure.golden == "absent.golden"
      assert {:golden_unreadable, :enoent} = failure.reason
    end
  end

  describe "script — ordered sub-invocations" do
    test "a 3-step script passes only when ALL steps pass", %{workspace: ws} do
      config = %{
        cmd: "sh",
        script: [
          step("echo one; exit 0", 0),
          step("echo two; exit 0", 0),
          step("echo three; exit 0", 0)
        ]
      }

      assert %PredicateResult{status: :pass, score: 3.0, direction: :higher_better} =
               result = evaluate(config, ws)

      assert result.evidence.passing_steps == 3
      assert result.evidence.steps_required == 3
      assert length(result.evidence.steps) == 3
    end

    test "a failing step FAILS the script naming the SPECIFIC step", %{workspace: ws} do
      config = %{
        cmd: "sh",
        script: [
          step("echo one; exit 0", 0),
          # step 2 exits 3 against an expected 0 — the specific failing step.
          step("echo boom; exit 3", 0),
          step("echo three; exit 0", 0)
        ]
      }

      assert %PredicateResult{status: :fail, score: 1.0, direction: :higher_better} =
               result = evaluate(config, ws)

      assert result.evidence.failed_step.index == 2
      assert [failure] = result.evidence.failed_step.assertion_failures
      assert failure.target == "exit_code"
      assert failure.expected == 0
      assert failure.found == 3

      # Fail-fast: the step after the failing one never ran.
      assert length(result.evidence.steps) == 2
    end

    test "an unlaunchable binary in a script is :error, never :fail", %{workspace: ws} do
      config = %{
        cmd: "kazi-definitely-not-a-real-binary-xyz",
        script: [step("ignored", 0)]
      }

      assert %PredicateResult{status: :error} = evaluate(config, ws)
    end
  end

  describe "samples — N consecutive passing runs" do
    test "samples: 3 requires 3 CONSECUTIVE passing runs", %{workspace: ws} do
      # A counter in the workspace: runs 1 and 2 exit 0 (pass), run 3 exits 1 (fail).
      counter =
        "n=$(cat n 2>/dev/null || echo 0); n=$((n+1)); printf %s \"$n\" > n; [ \"$n\" -lt 3 ]"

      config =
        Map.merge(sh(counter), %{
          samples: 3,
          assertions: [%{"target" => "exit_code", "expected" => 0}]
        })

      assert %PredicateResult{status: :fail} = result = evaluate(config, ws)
      # Two passed before the streak broke on the third run — not yet stably green.
      assert result.evidence.passing_count == 2
      assert result.evidence.samples_required == 3
    end

    test "samples: 3 passes when all 3 runs pass", %{workspace: ws} do
      config =
        Map.merge(sh("exit 0"), %{
          samples: 3,
          assertions: [%{"target" => "exit_code", "expected" => 0}]
        })

      assert %PredicateResult{status: :pass, score: 3.0} = result = evaluate(config, ws)
      assert result.evidence.passing_count == 3
    end
  end

  # A script step: an invocation of the shared `cmd` (`sh`) with its own args +
  # an exit_code assertion.
  defp step(script, expected_exit) do
    %{
      "args" => ["-c", script],
      "assertions" => [%{"target" => "exit_code", "expected" => expected_exit}]
    }
  end
end

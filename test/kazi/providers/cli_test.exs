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
  end
end

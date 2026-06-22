defmodule Kazi.Providers.TestRunnerTest do
  # Tier 2: real boundary. These run actual commands via System.cmd in a temp
  # workspace and assert the resulting PredicateResult, proving the provider maps
  # real exit codes + output to the contract (T0.5, UC-002).
  use ExUnit.Case, async: true

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Providers.TestRunner

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_test_runner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  defp predicate(config), do: Predicate.new(:unit, :tests, config: config)

  test "implements the PredicateProvider behaviour" do
    behaviours = TestRunner.module_info(:attributes)[:behaviour] || []
    assert Kazi.PredicateProvider in behaviours
  end

  test "exit 0 -> :pass with command + exit code in evidence", %{workspace: ws} do
    result =
      TestRunner.evaluate(predicate(%{cmd: "sh", args: ["-c", "exit 0"]}), %{workspace: ws})

    assert %PredicateResult{status: :pass} = result
    assert result.evidence.exit == 0
    assert result.evidence.cmd == "sh"
    assert result.evidence.workspace == ws
  end

  test "non-zero exit -> :fail (not :error) with exit code in evidence", %{workspace: ws} do
    result =
      TestRunner.evaluate(predicate(%{cmd: "sh", args: ["-c", "exit 1"]}), %{workspace: ws})

    assert result.status == :fail
    assert result.evidence.exit == 1
  end

  test "captures stdout and stderr together in evidence output", %{workspace: ws} do
    config = %{cmd: "sh", args: ["-c", "echo to_out; echo to_err 1>&2; exit 3"]}
    result = TestRunner.evaluate(predicate(config), %{workspace: ws})

    assert result.status == :fail
    assert result.evidence.exit == 3
    assert result.evidence.output =~ "to_out"
    assert result.evidence.output =~ "to_err"
  end

  test "runs the command in the target workspace", %{workspace: ws} do
    File.write!(Path.join(ws, "marker.txt"), "here")
    # `test -f` succeeds (exit 0) only if the command ran with cwd == workspace.
    result =
      TestRunner.evaluate(predicate(%{cmd: "sh", args: ["-c", "test -f marker.txt"]}), %{
        workspace: ws
      })

    assert result.status == :pass
  end

  test "missing/invalid command path -> :error, no crash", %{workspace: ws} do
    config = %{cmd: "kazi_no_such_binary_#{System.unique_integer([:positive])}"}
    result = TestRunner.evaluate(predicate(config), %{workspace: ws})

    assert %PredicateResult{status: :error} = result
    assert match?({:cmd_unrunnable, _}, result.evidence.reason)
  end

  test "absent :cmd in config -> :error, not a crash", %{workspace: ws} do
    result = TestRunner.evaluate(predicate(%{}), %{workspace: ws})

    assert result.status == :error
    assert result.evidence.reason == :missing_cmd
  end

  test "non-:tests predicate kind -> :error" do
    result = TestRunner.evaluate(Predicate.new(:probe, :http_probe), %{})
    assert %PredicateResult{status: :error} = result
    assert match?({:unsupported_kind, :http_probe}, result.evidence.reason)
  end

  test "defaults workspace to cwd when context omits it" do
    result = TestRunner.evaluate(predicate(%{cmd: "sh", args: ["-c", "exit 0"]}), %{})
    assert result.status == :pass
    assert result.evidence.workspace == File.cwd!()
  end
end

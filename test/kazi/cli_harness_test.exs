defmodule Kazi.CLIHarnessTest do
  # T8.7 (UC-026/UC-027, ADR-0016): the CLI harness-selection wiring. Proves that
  # `kazi run --harness <id> --model <m>` resolves the generic CliAdapter with the
  # named profile and dispatches it, and that with NO --harness the default path is
  # the claude profile (byte-identical selection to pre-T8.7).
  #
  # Tier 2, hermetic: the harness is a stub binary (injected via the test-only
  # adapter_opts :command seam) that records the argv it received and creates the
  # marker file the goal's test_runner predicate checks, so the dispatched run
  # converges. No network, no real claude/opencode, no read-model (persist?: false).
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @stub Path.expand("../support/stub_harness_argv.sh", __DIR__)

  setup do
    work = Path.join(System.tmp_dir!(), "kazi-cli-harness-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf!(work) end)
    {:ok, work: work}
  end

  # A minimal goal: one test_runner predicate failing at t0 (fixed.txt absent),
  # which the dispatched harness stub makes pass by creating fixed.txt.
  defp write_goal(work) do
    path = Path.join(work, "goal.toml")

    File.write!(path, """
    id = "cli-harness"
    name = "CLI harness selection"

    [scope]
    workspace = "#{work}"

    [[predicate]]
    id = "code"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  defp argv_lines(work) do
    work |> Path.join("harness_argv.txt") |> File.read!() |> String.split("\n", trim: true)
  end

  test "`run --harness opencode --model m` dispatches via the opencode profile", %{work: work} do
    goal = write_goal(work)

    {code, _io} =
      with_io(fn ->
        Kazi.CLI.run(
          ["run", goal, "--workspace", work, "--harness", "opencode", "--model", "dgx/qwen3.6"],
          adapter_opts: [command: @stub],
          persist?: false
        )
      end)

    assert code == 0, "expected convergence (exit 0) driving the opencode-profile stub"

    # The argv the stub received proves the opencode profile assembled it:
    # `opencode run <prompt> --model dgx/qwen3.6 --format json` (the command itself
    # is the stub; argv is everything after it).
    argv = argv_lines(work)
    assert "run" in argv
    assert "--format" in argv
    assert "json" in argv
    assert "--model" in argv
    assert "dgx/qwen3.6" in argv
    # NOT the claude shape.
    refute "-p" in argv
    refute "--output-format" in argv
  end

  test "`run` with no --harness defaults to the claude profile", %{work: work} do
    goal = write_goal(work)

    {code, _io} =
      with_io(fn ->
        Kazi.CLI.run(["run", goal, "--workspace", work],
          adapter_opts: [command: @stub],
          persist?: false
        )
      end)

    assert code == 0

    # The default claude profile shape: `-p <prompt> --output-format json`.
    argv = argv_lines(work)
    assert "-p" in argv
    assert "--output-format" in argv
    assert "json" in argv
    refute "run" in argv
    refute "--format" in argv
  end

  test "an unknown --harness id fails with a clear message", %{work: work} do
    goal = write_goal(work)

    {code, stderr} =
      with_io(:stderr, fn ->
        Kazi.CLI.run(["run", goal, "--workspace", work, "--harness", "nope"], persist?: false)
      end)

    assert code == 1
    assert stderr =~ "unknown harness"
    assert stderr =~ "claude"
  end
end

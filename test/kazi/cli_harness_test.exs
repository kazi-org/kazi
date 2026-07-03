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
          [
            "apply",
            goal,
            "--workspace",
            work,
            "--harness",
            "opencode",
            "--model",
            "local/qwen3.6"
          ],
          adapter_opts: [command: @stub],
          persist?: false
        )
      end)

    assert code == 0, "expected convergence (exit 0) driving the opencode-profile stub"

    # The argv the stub received proves the opencode profile assembled it:
    # `opencode run <prompt> --model local/qwen3.6 --format json` (the command itself
    # is the stub; argv is everything after it).
    argv = argv_lines(work)
    assert "run" in argv
    assert "--format" in argv
    assert "json" in argv
    assert "--model" in argv
    assert "local/qwen3.6" in argv
    # NOT the claude shape.
    refute "-p" in argv
    refute "--output-format" in argv
  end

  test "`run` with no --harness defaults to the claude profile", %{work: work} do
    goal = write_goal(work)

    {code, _io} =
      with_io(fn ->
        Kazi.CLI.run(["apply", goal, "--workspace", work],
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

  # The goal-file variant: a `[harness]` table that authors an `effort` level.
  defp write_goal_with_effort(work, effort) do
    path = Path.join(work, "goal.toml")

    File.write!(path, """
    id = "cli-harness"
    name = "CLI harness selection"

    [scope]
    workspace = "#{work}"

    [harness]
    id = "claude"
    effort = "#{effort}"

    [[predicate]]
    id = "code"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  test "`apply --effort high` reaches the claude harness argv (T36.6)", %{work: work} do
    goal = write_goal(work)

    {code, _io} =
      with_io(fn ->
        Kazi.CLI.run(["apply", goal, "--workspace", work, "--effort", "high"],
          adapter_opts: [command: @stub],
          persist?: false
        )
      end)

    assert code == 0

    # The claude profile renders `--effort <level>` as a contiguous pair.
    argv = argv_lines(work)
    assert "-p" in argv
    assert "--effort" in argv
    assert effort_value(argv) == "high"
  end

  test "a goal-file `[harness] effort` reaches the argv with no CLI flag (T36.6)", %{work: work} do
    goal = write_goal_with_effort(work, "medium")

    {code, _io} =
      with_io(fn ->
        Kazi.CLI.run(["apply", goal, "--workspace", work],
          adapter_opts: [command: @stub],
          persist?: false
        )
      end)

    assert code == 0

    argv = argv_lines(work)
    assert "--effort" in argv
    assert effort_value(argv) == "medium"
  end

  test "the CLI `--effort` flag OVERRIDES the goal-file `[harness] effort` (T36.6)", %{work: work} do
    goal = write_goal_with_effort(work, "medium")

    {code, _io} =
      with_io(fn ->
        Kazi.CLI.run(["apply", goal, "--workspace", work, "--effort", "high"],
          adapter_opts: [command: @stub],
          persist?: false
        )
      end)

    assert code == 0

    # CLI > goal-file precedence: the rendered level is the flag's, not the file's.
    argv = argv_lines(work)
    assert effort_value(argv) == "high"
    refute "medium" in argv
  end

  test "no --effort and no goal-file effort leaves the argv with no --effort (T36.6)", %{
    work: work
  } do
    goal = write_goal(work)

    {code, _io} =
      with_io(fn ->
        Kazi.CLI.run(["apply", goal, "--workspace", work],
          adapter_opts: [command: @stub],
          persist?: false
        )
      end)

    assert code == 0
    refute "--effort" in argv_lines(work)
  end

  # The token immediately after `--effort` in the recorded argv.
  defp effort_value(argv) do
    idx = Enum.find_index(argv, &(&1 == "--effort"))
    if idx, do: Enum.at(argv, idx + 1)
  end

  # The goal-file variant: a `[harness]` table that authors permission_mode/
  # allowed_tools (issue #769).
  defp write_goal_with_permission(work, permission_mode, allowed_tools) do
    path = Path.join(work, "goal.toml")

    File.write!(path, """
    id = "cli-harness"
    name = "CLI harness selection"

    [scope]
    workspace = "#{work}"

    [harness]
    id = "claude"
    permission_mode = "#{permission_mode}"
    allowed_tools = #{inspect(allowed_tools)}

    [[predicate]]
    id = "code"
    provider = "test_runner"
    cmd = "sh"
    args = ["-c", "test -f fixed.txt"]
    """)

    path
  end

  test "`apply --permission-mode acceptEdits --allowed-tools Write,Bash` reaches the claude harness argv (issue #769)",
       %{work: work} do
    goal = write_goal(work)

    {code, _io} =
      with_io(fn ->
        Kazi.CLI.run(
          [
            "apply",
            goal,
            "--workspace",
            work,
            "--permission-mode",
            "acceptEdits",
            "--allowed-tools",
            "Write,Bash"
          ],
          adapter_opts: [command: @stub],
          persist?: false
        )
      end)

    assert code == 0

    argv = argv_lines(work)
    assert "--permission-mode" in argv
    assert permission_mode_value(argv) == "acceptEdits"
    assert "--allowed-tools" in argv
    assert "Write" in argv
    assert "Bash" in argv
  end

  test "a goal-file `[harness] permission_mode`/`allowed_tools` reaches the argv with no CLI flags (issue #769)",
       %{work: work} do
    goal = write_goal_with_permission(work, "plan", ["Edit", "Read"])

    {code, _io} =
      with_io(fn ->
        Kazi.CLI.run(["apply", goal, "--workspace", work],
          adapter_opts: [command: @stub],
          persist?: false
        )
      end)

    assert code == 0

    argv = argv_lines(work)
    assert permission_mode_value(argv) == "plan"
    assert "Edit" in argv
    assert "Read" in argv
  end

  test "the CLI `--permission-mode`/`--allowed-tools` flags OVERRIDE the goal-file `[harness]` fields (issue #769)",
       %{work: work} do
    goal = write_goal_with_permission(work, "plan", ["Edit", "Read"])

    {code, _io} =
      with_io(fn ->
        Kazi.CLI.run(
          [
            "apply",
            goal,
            "--workspace",
            work,
            "--permission-mode",
            "bypassPermissions",
            "--allowed-tools",
            "Write"
          ],
          adapter_opts: [command: @stub],
          persist?: false
        )
      end)

    assert code == 0

    # CLI > goal-file precedence: the rendered values are the flags', not the
    # file's. Read off the `--allowed-tools` values specifically (not blanket
    # argv membership) — Edit/Read/Write/Bash are ALSO always present in the
    # separate, unrelated `--tools` standard-tools flag (dispatch_surface.ex),
    # so a bare `"Edit" in argv` check would false-positive on that flag.
    argv = argv_lines(work)
    assert permission_mode_value(argv) == "bypassPermissions"
    refute "plan" in argv
    assert allowed_tools_values(argv) == ["Write"]
  end

  test "no --permission-mode/--allowed-tools and no goal-file fields leave the argv with neither flag (issue #769)",
       %{work: work} do
    goal = write_goal(work)

    {code, _io} =
      with_io(fn ->
        Kazi.CLI.run(["apply", goal, "--workspace", work],
          adapter_opts: [command: @stub],
          persist?: false
        )
      end)

    assert code == 0

    argv = argv_lines(work)
    refute "--permission-mode" in argv
    refute "--allowed-tools" in argv
  end

  # The token immediately after `--permission-mode` in the recorded argv.
  defp permission_mode_value(argv) do
    idx = Enum.find_index(argv, &(&1 == "--permission-mode"))
    if idx, do: Enum.at(argv, idx + 1)
  end

  # The tokens between `--allowed-tools` and the next flag in the recorded argv
  # (the claude profile renders it as a variadic `--allowed-tools <t> <t> …`).
  # Deliberately scoped to just that flag's values, not blanket argv membership
  # — Read/Edit/Write/Bash/Glob/Grep are ALSO always present in the separate,
  # unrelated `--tools` standard-tools flag (dispatch_surface.ex).
  defp allowed_tools_values(argv) do
    idx = Enum.find_index(argv, &(&1 == "--allowed-tools"))

    if idx do
      argv |> Enum.drop(idx + 1) |> Enum.take_while(&(not String.starts_with?(&1, "--")))
    else
      []
    end
  end

  test "an unknown --harness id fails with a clear message", %{work: work} do
    goal = write_goal(work)

    {code, stderr} =
      with_io(:stderr, fn ->
        Kazi.CLI.run(["apply", goal, "--workspace", work, "--harness", "nope"], persist?: false)
      end)

    assert code == 1
    assert stderr =~ "unknown harness"

    # T14.5/T37.1 (ADR-0022): the `available:` list is derived from `Registry.ids/0`,
    # so it must name every built-in harness — claude, opencode, codex, antigravity,
    # claw, gemini_cli — not just the original two. This pins the auto-derivation:
    # registering a new profile in `ids/0` surfaces it in the CLI error with no
    # cli.ex change.
    for id <- ~w(claude opencode codex antigravity claw gemini_cli) do
      assert stderr =~ id
    end
  end
end

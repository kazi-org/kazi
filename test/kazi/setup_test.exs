defmodule Kazi.SetupTest do
  @moduledoc """
  ADR-0088 (#1642): unit coverage for `Kazi.Setup.run/3` — the declared
  `[setup]` provisioning commands the controller runs ONCE, in the workspace,
  before the t0 observation. `run/3` runs every command IN ORDER, stops at the
  FIRST failure, and reports a `{:setup_failed, failure}` tuple naming the
  offending command/reason/detail — never a predicate verdict.
  """
  use ExUnit.Case, async: true

  doctest Kazi.Setup

  alias Kazi.Setup

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi-setup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "no-ops (byte-identical to before this feature existed)" do
    test "nil setup no-ops" do
      assert Setup.run(nil, "/tmp", []) == :ok
    end

    test "an empty commands list no-ops" do
      assert Setup.run(Setup.new(), "/tmp", []) == :ok
    end
  end

  describe "new/1 defaults" do
    test "timeout_ms defaults when not declared" do
      assert Setup.new().timeout_ms == Setup.default_timeout_ms()
      assert Setup.new().commands == []
    end

    test "commands + timeout_ms are set from opts" do
      setup_step = Setup.new(commands: ["mix deps.get"], timeout_ms: 42)
      assert setup_step.commands == ["mix deps.get"]
      assert setup_step.timeout_ms == 42
    end
  end

  describe "run/3 — success" do
    test "every command runs to exit 0, IN ORDER, in the workspace", %{dir: dir} do
      setup_step = Setup.new(commands: ["echo one > a.txt", "echo two > b.txt"])

      assert Setup.run(setup_step, dir, []) == :ok
      assert File.read!(Path.join(dir, "a.txt")) == "one\n"
      assert File.read!(Path.join(dir, "b.txt")) == "two\n"
    end
  end

  describe "run/3 — failure is a distinct {:setup_failed, _}, never a predicate verdict" do
    test "a non-zero exit stops at the FIRST failing command and names it", %{dir: dir} do
      setup_step = Setup.new(commands: ["touch ran.marker", "exit 7", "touch never.marker"])

      assert {:error, {:setup_failed, failure}} = Setup.run(setup_step, dir, [])
      assert failure.command == "exit 7"
      assert failure.index == 1
      assert failure.reason == :exit_code
      assert failure.detail =~ "exit 7"

      assert File.exists?(Path.join(dir, "ran.marker")),
             "the command BEFORE the failure must still have run"

      refute File.exists?(Path.join(dir, "never.marker")),
             "a command AFTER the failure must never run"
    end

    test "an overrunning command times out and is reported distinctly", %{dir: dir} do
      setup_step = Setup.new(commands: ["sleep 5"], timeout_ms: 100)

      assert {:error, {:setup_failed, failure}} = Setup.run(setup_step, dir, [])
      assert failure.reason == :timeout
      assert failure.detail =~ "100ms"
    end

    test "command output over the truncation cap is bounded, never dumped unbounded", %{
      dir: dir
    } do
      # A big write followed by a failing exit — the failure detail must stay bounded.
      setup_step = Setup.new(commands: ["yes x | head -c 20000; exit 3"])

      assert {:error, {:setup_failed, failure}} = Setup.run(setup_step, dir, [])
      assert failure.reason == :exit_code
      assert String.length(failure.detail) < 4200
      assert failure.detail =~ "truncated"
    end
  end

  describe "the injectable :command_runner seam" do
    test "opts[:command_runner] overrides execution, with the same contract as CommandRunner.run/4" do
      test_pid = self()

      runner = fn cmd, args, cmd_opts, timeout_ms ->
        send(test_pid, {:ran, cmd, args, cmd_opts, timeout_ms})
        {:ran, "", 0}
      end

      setup_step = Setup.new(commands: ["mix deps.get"], timeout_ms: 42)

      assert Setup.run(setup_step, "/tmp/ws", command_runner: runner) == :ok

      assert_received {:ran, "sh", ["-c", "mix deps.get"], cmd_opts, 42}
      assert cmd_opts[:cd] == "/tmp/ws"
      assert cmd_opts[:stderr_to_stdout] == true
    end

    test "an injected runner's :setup_failed shape matches the real one" do
      runner = fn _cmd, _args, _opts, _timeout -> {:raised, "no such file or directory"} end
      setup_step = Setup.new(commands: ["ghost-binary"])

      assert {:error, {:setup_failed, failure}} =
               Setup.run(setup_step, "/tmp", command_runner: runner)

      assert failure == %{
               command: "ghost-binary",
               index: 0,
               reason: :raised,
               detail: "no such file or directory"
             }
    end
  end
end

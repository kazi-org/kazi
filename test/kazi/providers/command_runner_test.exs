defmodule Kazi.Providers.CommandRunnerTest do
  # async: false — the release-env-scrubbing cases mutate the OS environment
  # (System.put_env / delete_env) to simulate the burrito CLI's leaked footprint,
  # which is process-global and would race other async tests.
  use ExUnit.Case, async: false

  alias Kazi.Providers.CommandRunner

  describe "run/4 — the basic RAN / RAISED / TIMEOUT contract" do
    test "a command that runs is {:ran, output, exit_code} regardless of exit code" do
      assert {:ran, out, 0} = CommandRunner.run("bash", ["-c", "echo hi"], stderr_to_stdout: true)
      assert out =~ "hi"
      assert {:ran, _out, 3} = CommandRunner.run("bash", ["-c", "exit 3"], stderr_to_stdout: true)
    end

    test "a missing binary is {:raised, _}, never a crash" do
      assert {:raised, _msg} = CommandRunner.run("kazi-no-such-binary-xyz", [], [])
    end
  end

  # L-0022: the burrito-packaged kazi binary exports its OWN release/ERTS
  # locators (BINDIR, ROOTDIR, RELEASE_*, __BURRITO*) into its environment. A
  # child process spawned by a predicate inherits them, and a nested `erl`/`mix`
  # honours BINDIR/ROOTDIR and execs the burrito `erlexec` — booting the kazi
  # release instead of the child's own BEAM (a nested `mix test` then crashes with
  # an opaque exit 2 / empty output, so kazi can never SEE the grader go green).
  # The command runner must scrub that footprint from every child it spawns, while
  # leaving ordinary inherited env and caller-supplied :env untouched.
  describe "run/4 — scrubs the host release/ERTS footprint from children (L-0022)" do
    @leaked %{
      "BINDIR" => "/nonexistent/.burrito/kazi/erts/bin",
      "ROOTDIR" => "/nonexistent/.burrito/kazi",
      "RELEASE_ROOT" => "/nonexistent/.burrito/kazi",
      "RELEASE_SYS_CONFIG" => "/nonexistent/.burrito/kazi/releases/9.9.9/sys",
      "__BURRITO" => "1",
      "__BURRITO_BIN_PATH" => "/nonexistent/bin/kazi"
    }

    setup do
      prior = Map.new(@leaked, fn {k, _} -> {k, System.get_env(k)} end)
      Enum.each(@leaked, fn {k, v} -> System.put_env(k, v) end)

      on_exit(fn ->
        Enum.each(prior, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end)

      :ok
    end

    test "none of the leaked release/ERTS vars reach the spawned child" do
      assert {:ran, out, 0} = CommandRunner.run("bash", ["-c", "env"], stderr_to_stdout: true)

      for var <- Map.keys(@leaked) do
        refute out =~ ~r/^#{var}=/m, "#{var} leaked into the spawned child"
      end
    end

    test "the scrub holds on the timeout path too" do
      assert {:ran, out, 0} =
               CommandRunner.run("bash", ["-c", "env"], [stderr_to_stdout: true], 30_000)

      refute out =~ ~r/^BINDIR=/m
      refute out =~ ~r/^ROOTDIR=/m
    end

    test "ordinary inherited env and caller-supplied :env still pass through" do
      System.put_env("KAZI_CR_INHERITED", "kept")
      on_exit(fn -> System.delete_env("KAZI_CR_INHERITED") end)

      assert {:ran, out, 0} =
               CommandRunner.run("bash", ["-c", "env"],
                 env: [{"KAZI_CR_EXTRA", "added"}],
                 stderr_to_stdout: true
               )

      assert out =~ ~r/^KAZI_CR_INHERITED=kept$/m, "scrub must not drop ordinary inherited env"
      assert out =~ ~r/^KAZI_CR_EXTRA=added$/m, "scrub must not drop caller-supplied :env"
    end
  end
end

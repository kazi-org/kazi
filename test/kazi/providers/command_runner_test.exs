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

  # L-0022 (PATH facet): the release env.sh PREPENDS the release's own
  # `$RELEASE_ROOT/bin` + `$RELEASE_ROOT/erts-*/bin` to PATH. Those dirs hold the
  # release BOOT SCRIPT (named `kazi` for the burrito binary), which shadows the
  # operator's real `kazi` launcher on a child's PATH — a nested `kazi <verb>`
  # then resolves to the boot script and is rejected ("Unknown command <verb>").
  # The command runner must strip any PATH entry under RELEASE_ROOT from every
  # child it spawns, while keeping the rest of PATH intact.
  describe "run/4 — strips the release's own bin dirs from the child PATH (L-0022)" do
    setup do
      root = "/nonexistent/.burrito/kazi_erts-9.9.9_9.9.9"

      prior_root = System.get_env("RELEASE_ROOT")
      prior_path = System.get_env("PATH")

      # Simulate the release footprint: RELEASE_ROOT set, with the release's own
      # bin + erts/bin PREPENDED to an otherwise-real PATH.
      System.put_env("RELEASE_ROOT", root)
      System.put_env("PATH", "#{root}/erts-9.9.9/bin:#{root}/bin:#{prior_path}")

      on_exit(fn ->
        if prior_root,
          do: System.put_env("RELEASE_ROOT", prior_root),
          else: System.delete_env("RELEASE_ROOT")

        System.put_env("PATH", prior_path)
      end)

      %{root: root, real_path: prior_path}
    end

    test "the release bin dirs are gone from the child PATH; the rest survives", %{
      root: root,
      real_path: real_path
    } do
      assert {:ran, out, 0} =
               CommandRunner.run("bash", ["-c", "echo \"PATH=$PATH\""], stderr_to_stdout: true)

      [child_path] = Regex.run(~r/^PATH=(.*)$/m, out, capture: :all_but_first)
      entries = String.split(child_path, ":", trim: true)

      refute Enum.any?(entries, &String.starts_with?(&1, root)),
             "release bin dirs must not reach the child PATH (got #{child_path})"

      # Every non-release dir the parent had is still present (nothing else stripped).
      for dir <- String.split(real_path, ":", trim: true) do
        assert dir in entries, "scrub dropped a non-release PATH dir: #{dir}"
      end
    end

    test "from source (no RELEASE_ROOT) the inherited PATH is left untouched" do
      System.delete_env("RELEASE_ROOT")
      real = System.get_env("PATH")

      assert {:ran, out, 0} =
               CommandRunner.run("bash", ["-c", "echo \"PATH=$PATH\""], stderr_to_stdout: true)

      [child_path] = Regex.run(~r/^PATH=(.*)$/m, out, capture: :all_but_first)
      assert child_path == real, "PATH must be inherited verbatim when not running from a release"
    end
  end
end

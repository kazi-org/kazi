defmodule Kazi.Goal.ProviderDeprecationTest do
  @moduledoc """
  T32.1b (ADR-0040 decisions 1 + 7): the command-runner providers `test_runner`
  and `prod_log` are folded onto the unified `custom_script` core and DEPRECATED
  (removed in v2.0.0). The fold ships NON-BREAKING: both names still resolve, an
  existing goal-file still loads + evaluates byte-identically via the preset, and
  the only new surface is a one-line migration hint emitted to STDERR — never into
  `--json` stdout.

  These cases pin every acceptance bullet:

    * back-compat — a `test_runner` goal evaluates byte-identically to its
      `custom_script verdict = "exit_zero"` equivalent (the preset IS that config);
      a `prod_log` goal keeps its specialised 5xx/panic evidence;
    * the loader emits the STDERR deprecation hint (deduped per provider) and
      keeps STDOUT pure;
    * the migration target + v2.0.0 removal are documented.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Kazi.{Predicate, PredicateResult}
  alias Kazi.Goal.Loader
  alias Kazi.Providers.{CustomScript, ProdLog, TestRunner}

  setup do
    dir = Path.join(System.tmp_dir!(), "kazi_dep_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, workspace: dir}
  end

  # Write a goal-file with the given [[predicate]] body and return its path. Loads
  # run against the workspace dir so a relative-path checker resolves there.
  defp write_goal(dir, predicates) do
    path = Path.join(dir, "goal_#{System.unique_integer([:positive])}.toml")

    File.write!(path, """
    id = "dep-fixture"
    name = "deprecation fixture"

    [scope]
    workspace = "#{dir}"

    #{predicates}
    """)

    path
  end

  describe "back-compat — test_runner folds onto custom_script byte-identically" do
    test "the test_runner preset == the custom_script exit_zero config it rewrites to",
         %{workspace: ws} do
      # A command writing to BOTH streams with a non-zero exit: it exercises the
      # exit_zero verdict (-> :fail) AND the merged-stderr capture the preset sets.
      cmd = "sh"
      args = ["-c", "echo to_out; echo to_err 1>&2; exit 7"]
      context = %{workspace: ws}

      preset =
        TestRunner.evaluate(
          Predicate.new(:unit, :tests, config: %{cmd: cmd, args: args}),
          context
        )

      explicit =
        CustomScript.evaluate(
          Predicate.new(:unit, :custom_script,
            config: %{cmd: cmd, args: args, verdict: "exit_zero", merge_stderr: true}
          ),
          context
        )

      # Byte-identical: same status, same evidence map (incl. the combined stream
      # and the resolved verdict). The preset adds NOTHING the unified core lacks.
      assert preset == explicit
      assert %PredicateResult{status: :fail} = preset
      assert preset.evidence.exit == 7
      assert preset.evidence.verdict == "exit_zero"
      assert preset.evidence.output =~ "to_out"
      assert preset.evidence.output =~ "to_err"
    end

    test "a loaded test_runner goal still evaluates green on exit 0", %{workspace: ws} do
      File.write!(Path.join(ws, "fixed.txt"), "ok")

      path =
        write_goal(ws, """
        [[predicate]]
        id = "code"
        provider = "test_runner"
        cmd = "sh"
        args = ["-c", "test -f fixed.txt"]
        """)

      assert {:ok, goal} = Loader.load(path)
      assert [%Predicate{id: "code", kind: :tests} = pred] = goal.predicates
      assert TestRunner.evaluate(pred, %{workspace: ws}).status == :pass
    end
  end

  describe "back-compat — prod_log keeps its specialised evidence over the shared core" do
    test "a loaded prod_log goal evaluates with 5xx/panic evidence intact", %{workspace: ws} do
      # The query command emits one 5xx line and no panic; with the default 5xx
      # threshold of 0 that is a :fail carrying prod_log's bespoke evidence keys.
      path =
        write_goal(ws, """
        [[predicate]]
        id = "logs"
        provider = "prod_log"
        cmd = "sh"
        args = ["-c", "echo 'GET /x 503'"]
        """)

      assert {:ok, goal} = Loader.load(path)
      assert [%Predicate{id: "logs", kind: :prod_log} = pred] = goal.predicates

      result = ProdLog.evaluate(pred, %{workspace: ws})
      assert result.status == :fail
      # prod_log's evidence shape is UNCHANGED by the CommandRunner refactor:
      # match_count's generic count could not reproduce these keys byte-for-byte.
      assert result.evidence.server_error_count == 1
      assert result.evidence.panic_count == 0
      assert Map.has_key?(result.evidence, :max_5xx)
      assert result.evidence.matched_lines == ["GET /x 503"]
    end
  end

  describe "deprecation hint — STDERR only, deduped, pure STDOUT" do
    test "loading a test_runner goal emits a one-line STDERR migration hint", %{workspace: ws} do
      path =
        write_goal(ws, """
        [[predicate]]
        id = "code"
        provider = "test_runner"
        cmd = "sh"
        args = ["-c", "exit 0"]
        """)

      stderr = capture_io(:stderr, fn -> assert {:ok, _} = Loader.load(path) end)

      assert stderr =~ "test_runner"
      assert stderr =~ "deprecated"
      assert stderr =~ "v2.0.0"
      assert stderr =~ "custom_script (verdict = \"exit_zero\")"
      assert stderr =~ "docs/deprecations.md"
    end

    test "the prod_log hint names its match_count migration target", %{workspace: ws} do
      path =
        write_goal(ws, """
        [[predicate]]
        id = "logs"
        provider = "prod_log"
        cmd = "sh"
        args = ["-c", "true"]
        """)

      stderr = capture_io(:stderr, fn -> assert {:ok, _} = Loader.load(path) end)
      assert stderr =~ "prod_log"
      assert stderr =~ "custom_script (verdict = \"match_count\")"
    end

    test "the hint is emitted once per provider even with many deprecated predicates",
         %{workspace: ws} do
      path =
        write_goal(ws, """
        [[predicate]]
        id = "a"
        provider = "test_runner"
        cmd = "sh"
        args = ["-c", "exit 0"]

        [[predicate]]
        id = "b"
        provider = "test_runner"
        cmd = "sh"
        args = ["-c", "exit 0"]
        """)

      stderr = capture_io(:stderr, fn -> assert {:ok, _} = Loader.load(path) end)
      occurrences = stderr |> String.split("test_runner") |> length() |> Kernel.-(1)
      assert occurrences == 1
    end

    test "STDOUT stays pure while the hint goes to STDERR (the --json contract)",
         %{workspace: ws} do
      path =
        write_goal(ws, """
        [[predicate]]
        id = "code"
        provider = "test_runner"
        cmd = "sh"
        args = ["-c", "exit 0"]
        """)

      # The group-leader (stdout) stream a `--json` caller reads carries NOTHING
      # from the load; the advisory hint is on STDERR alone.
      stdout = capture_io(fn -> assert {:ok, _} = Loader.load(path) end)
      assert stdout == ""
    end

    test "a goal that uses only custom_script / http_probe emits NO hint", %{workspace: ws} do
      path =
        write_goal(ws, """
        [[predicate]]
        id = "code"
        provider = "custom_script"
        verdict = "exit_zero"
        cmd = "sh"
        args = ["-c", "exit 0"]
        """)

      stderr = capture_io(:stderr, fn -> assert {:ok, _} = Loader.load(path) end)
      refute stderr =~ "deprecated"
    end
  end

  describe "deprecation docs land with the code" do
    test "docs/deprecations.md names the aliases, the migration, and the v2.0.0 removal" do
      doc = File.read!(Path.join(File.cwd!(), "docs/deprecations.md"))

      assert doc =~ "test_runner"
      assert doc =~ "prod_log"
      assert doc =~ "v2.0.0"
      assert doc =~ "custom_script"
      assert doc =~ ~r/migrat/i
    end
  end
end

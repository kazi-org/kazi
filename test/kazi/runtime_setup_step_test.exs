defmodule Kazi.RuntimeSetupStepTest do
  @moduledoc """
  T69.12 / ADR-0088 (issue #1642): a build-tool-backed predicate is red at t0
  for an ENVIRONMENTAL reason in a freshly created `git worktree` with no
  provisioned dependencies — nothing in the worktree-creation/preflight path
  runs `mix deps.get` (or any language-appropriate equivalent) — defeating the
  "red-at-t0 proves the predicate measures real behavior" guarantee (concept
  R3). A declared `[setup]` step runs ONCE, in the workspace, BEFORE
  `Kazi.Runtime`'s t0 observation, so the predicate's t0 verdict reflects real
  product state instead of a missing dependency. A setup step that itself
  fails is a DISTINCT `{:error, {:setup_failed, _}}` result — never a
  predicate `:fail` verdict, mirroring the `{:error,
  {:startup_deadline_exceeded, _}}` environment-error shape issue #1683
  already established.

  Drives the REAL `Kazi.Runtime` assembly (a real git repo, real shell
  commands via the real `:custom_script` provider) — no mocks on the setup
  path itself.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kazi.{Goal, Predicate, PredicateVector, Runtime, Scope, Setup}

  @moduletag :tmp_dir

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Kazi.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Kazi.Repo, {:shared, self()})
    :ok
  end

  # A stand-in for a mix-backed predicate (e.g. `mix test`, which fails with
  # "Unchecked dependencies" against an unprovisioned checkout): without
  # provisioning, `vendor/` never exists in a freshly created worktree, so
  # this predicate is red for an ENVIRONMENTAL reason — the exact class issue
  # #1642 reports.
  defp deps_marker_predicate do
    Predicate.new(:deps_provisioned, :custom_script,
      config: %{cmd: "test", args: ["-f", "vendor/installed.marker"]}
    )
  end

  # The REAL, still-outstanding acceptance criterion — deliberately unmet, so
  # the goal is never vacuous regardless of the setup step's outcome.
  defp product_predicate do
    Predicate.new(:product_work, :custom_script,
      config: %{cmd: "test", args: ["-f", "fixed.txt"]}
    )
  end

  defp git_repo(tmp_dir) do
    work = Path.join(tmp_dir, "work-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", work], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: work)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: work)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: work)
    File.write!(Path.join(work, "seed.txt"), "seed\n")
    {_, 0} = System.cmd("git", ["add", "-A"], cd: work)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: work, stderr_to_stdout: true)
    work
  end

  defp harness_script(tmp_dir, name, body) do
    path = Path.join(tmp_dir, "harness-#{name}-#{System.unique_integer([:positive])}.sh")
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end

  describe "Kazi.Runtime.check/2 — the same t0 observation run/2 uses" do
    test "WITHOUT a [setup] block, the deps-dependent predicate is red at t0 for an \
environmental reason (the #1642 bug this feature fixes)",
         %{tmp_dir: tmp_dir} do
      work = git_repo(tmp_dir)

      goal =
        Goal.new("no-setup",
          predicates: [deps_marker_predicate(), product_predicate()],
          scope: Scope.new(workspace: work)
        )

      assert {:ok, %{status: :fail, vector: vector}} = Runtime.check(goal, workspace: work)
      assert PredicateVector.get(vector, :deps_provisioned).status == :fail
    end

    test "WITH a [setup] block declared, the SAME predicate is genuinely green at t0 — \
red/green is a product signal, not a missing-deps artifact",
         %{tmp_dir: tmp_dir} do
      work = git_repo(tmp_dir)

      goal =
        Goal.new("with-setup",
          predicates: [deps_marker_predicate(), product_predicate()],
          scope: Scope.new(workspace: work),
          setup: Setup.new(commands: ["mkdir -p vendor", "touch vendor/installed.marker"])
        )

      assert {:ok, %{status: :fail, vector: vector}} = Runtime.check(goal, workspace: work)
      assert PredicateVector.get(vector, :deps_provisioned).status == :pass

      # The REAL acceptance criterion is untouched by setup — still honestly
      # red, proving setup provisions the ENVIRONMENT, never the product.
      assert PredicateVector.get(vector, :product_work).status == :fail
    end
  end

  describe "a failing [setup] step is a distinct environment error, never a predicate verdict" do
    test "Runtime.check/2 refuses with {:setup_failed, _} before observing anything", %{
      tmp_dir: tmp_dir
    } do
      work = git_repo(tmp_dir)

      goal =
        Goal.new("failing-setup-check",
          predicates: [product_predicate()],
          scope: Scope.new(workspace: work),
          setup: Setup.new(commands: ["exit 9"])
        )

      assert {:error, {:setup_failed, failure}} = Runtime.check(goal, workspace: work)
      assert failure.command == "exit 9"
      assert failure.reason == :exit_code
    end

    test "Runtime.run/2 refuses with {:setup_failed, _} BEFORE any harness dispatch", %{
      tmp_dir: tmp_dir
    } do
      work = git_repo(tmp_dir)
      sentinel = Path.join(tmp_dir, "harness_ran.marker")
      harness = harness_script(tmp_dir, "sentinel", "touch #{inspect(sentinel)}\nexit 0")

      goal =
        Goal.new("failing-setup-run",
          predicates: [product_predicate()],
          scope: Scope.new(workspace: work),
          setup: Setup.new(commands: ["exit 9"])
        )

      assert {:error, {:setup_failed, failure}} =
               Runtime.run(goal,
                 workspace: work,
                 persist?: false,
                 adapter_opts: [command: harness]
               )

      assert failure.command == "exit 9"
      assert failure.reason == :exit_code

      refute File.exists?(sentinel),
             "the harness must never be dispatched when the [setup] step fails"
    end
  end

  describe "Kazi.Runtime.run/2 — the real apply path proceeds past a successful setup step" do
    test "a successful [setup] step lets the run reach real dispatch + convergence", %{
      tmp_dir: tmp_dir
    } do
      work = git_repo(tmp_dir)

      # The harness "fixes" the real product predicate — proving the run
      # proceeded PAST the setup step and the vacuous-goal guard into a real
      # dispatch/convergence cycle, exactly as issue #1642 says it should once
      # the environment is genuinely provisioned first.
      harness =
        harness_script(tmp_dir, "fixer", """
        echo done > fixed.txt
        exit 0
        """)

      goal =
        Goal.new("setup-then-converge",
          predicates: [deps_marker_predicate(), product_predicate()],
          scope: Scope.new(workspace: work),
          setup: Setup.new(commands: ["mkdir -p vendor", "touch vendor/installed.marker"])
        )

      assert {:ok, result} =
               Runtime.run(goal,
                 workspace: work,
                 persist?: false,
                 adapter_opts: [command: harness],
                 reobserve_interval_ms: 5,
                 await_timeout: 10_000
               )

      assert result.outcome == :converged
      assert File.exists?(Path.join(work, "vendor/installed.marker"))
      assert File.exists?(Path.join(work, "fixed.txt"))
    end
  end

  describe "the CLI surfaces a failing [setup] step distinctly (issue #1642)" do
    test "kazi apply --json reports a setup_failed reason, never a predicate result", %{
      tmp_dir: tmp_dir
    } do
      work = git_repo(tmp_dir)

      goal_file = Path.join(tmp_dir, "setup-failure.goal.toml")

      File.write!(goal_file, """
      id = "cli-setup-failure"

      [scope]
      workspace = #{inspect(work)}

      [setup]
      commands = ["exit 9"]

      [[predicate]]
      id = "code"
      provider = "custom_script"
      cmd = "test"
      args = ["-f", "fixed.txt"]
      """)

      harness = harness_script(tmp_dir, "unreachable", "exit 0")

      out =
        capture_io(fn ->
          code =
            Kazi.CLI.run(["apply", goal_file, "--workspace", work, "--json"],
              adapter_opts: [command: harness],
              persist?: false
            )

          send(self(), {:apply_exit_code, code})
        end)

      assert_received {:apply_exit_code, 1}

      json =
        out
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.find_value(fn line ->
          case Jason.decode(String.trim(line)) do
            {:ok, object} -> object
            _ -> nil
          end
        end)

      assert %{"status" => "error", "error" => message} = json
      assert message =~ "setup"
      assert message =~ "1642"
      assert message =~ "environment/provisioning error, not a predicate result"
    end
  end
end

defmodule Kazi.Goal.ScopeWriteGuardTest do
  @moduledoc """
  Issue #860: `[scope]` gains `write_paths` (the editable subset of the
  readable `paths` allow-list) and `deny` (protected paths that must never be
  modified by this goal). Covers:

    * the loader parses both, absent fields keeping today's behavior
      byte-identical;
    * `Kazi.Scope.guard_predicates/1` synthesizes a `:scope_guard` GUARD
      predicate from `deny`, independent of the `[enforcement]` profile;
    * `Kazi.Providers.ScopeGuard` fails (naming the offending paths) when a
      change lands under a `deny` path since the run's base ref, and passes
      otherwise;
    * the violation shows up as a FAILING predicate in the observed vector (the
      iteration record) and in `Kazi.Runtime.check/2`'s terminal result — the
      "at least soft" enforcement + "fed back to the inner agent as failing
      evidence" issue #860 asked for (no bespoke prompt wiring: guards flow
      through the SAME failing-evidence path every predicate uses).
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate, PredicateVector, Runtime, Scope}
  alias Kazi.Goal.Loader
  alias Kazi.Providers.{CustomScript, ScopeGuard}

  # ===========================================================================
  # 1. the loader parses [scope].write_paths and [scope].deny
  # ===========================================================================

  describe "Kazi.Goal.Loader parses [scope].write_paths and [scope].deny" do
    test "both fields parse into Kazi.Scope" do
      assert {:ok, %Goal{scope: scope}} =
               Loader.from_map(%{
                 "id" => "g",
                 "scope" => %{
                   "paths" => ["ios/"],
                   "write_paths" => ["ios/Watch/"],
                   "deny" => ["ios/Watch/Auth.plist"]
                 },
                 "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
               })

      assert scope.paths == ["ios/"]
      assert scope.write_paths == ["ios/Watch/"]
      assert scope.deny == ["ios/Watch/Auth.plist"]
    end

    test "absent write_paths/deny keep today's behavior byte-identical" do
      assert {:ok, %Goal{scope: scope}} =
               Loader.from_map(%{
                 "id" => "g",
                 "scope" => %{"paths" => ["lib/"]},
                 "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
               })

      assert scope.paths == ["lib/"]
      assert scope.write_paths == []
      assert scope.deny == []
    end

    test "a goal-file with no [scope] table at all still loads with empty scope fields" do
      assert {:ok, %Goal{scope: scope}} =
               Loader.from_map(%{
                 "id" => "g",
                 "predicate" => [%{"id" => "p", "provider" => "custom_script", "cmd" => "true"}]
               })

      assert scope.write_paths == []
      assert scope.deny == []
    end

    test "a non-list write_paths/deny is a validation error, like paths" do
      assert {:error, msg} =
               Loader.from_map(%{
                 "id" => "g",
                 "scope" => %{"write_paths" => "not-a-list"}
               })

      assert msg =~ "scope"
    end
  end

  # ===========================================================================
  # 2. Kazi.Scope.guard_predicates/1 synthesis
  # ===========================================================================

  describe "Kazi.Scope.guard_predicates/1" do
    test "an empty deny synthesizes no guard" do
      assert Scope.guard_predicates(Scope.new()) == []
      assert Scope.guard_predicates(Scope.new(paths: ["lib/"])) == []
    end

    test "a non-empty deny synthesizes one :scope_guard GUARD predicate" do
      assert [%Predicate{id: :scope_deny_paths, kind: :scope_guard, guard?: true} = guard] =
               Scope.guard_predicates(Scope.new(deny: ["ios/Auth.plist", "ci/"]))

      assert guard.config.deny == ["ios/Auth.plist", "ci/"]
      assert guard.description =~ "ios/Auth.plist"
    end
  end

  # ===========================================================================
  # 3. Kazi.Providers.ScopeGuard — the git-diff-backed check
  # ===========================================================================

  describe "Kazi.Providers.ScopeGuard.evaluate/2" do
    test "passes when nothing under a deny path changed" do
      dir = git_repo_with(%{"ios/Auth.plist" => "original", "lib/app.ex" => "code"})
      File.write!(Path.join(dir, "lib/app.ex"), "code v2")

      predicate = Predicate.new(:scope_deny_paths, :scope_guard, config: %{deny: ["ios/"]})
      result = ScopeGuard.evaluate(predicate, %{workspace: dir})

      assert result.status == :pass
    end

    test "fails, naming the offending path, when a deny path changed" do
      dir = git_repo_with(%{"ios/Auth.plist" => "original", "lib/app.ex" => "code"})
      File.write!(Path.join(dir, "ios/Auth.plist"), "tampered")

      predicate = Predicate.new(:scope_deny_paths, :scope_guard, config: %{deny: ["ios/"]})
      result = ScopeGuard.evaluate(predicate, %{workspace: dir})

      assert result.status == :fail
      assert result.evidence.changed == ["ios/Auth.plist"]
      assert result.evidence.reason == :deny_path_violation
    end

    test "a deny entry naming an exact file (not a directory) is respected" do
      dir = git_repo_with(%{"ios/Auth.plist" => "original", "ios/Other.plist" => "original"})
      File.write!(Path.join(dir, "ios/Other.plist"), "changed but not denied")

      predicate =
        Predicate.new(:scope_deny_paths, :scope_guard, config: %{deny: ["ios/Auth.plist"]})

      assert ScopeGuard.evaluate(predicate, %{workspace: dir}).status == :pass
    end

    test "no deny paths configured never fails" do
      dir = git_repo_with(%{"ios/Auth.plist" => "original"})
      File.write!(Path.join(dir, "ios/Auth.plist"), "tampered")

      predicate = Predicate.new(:scope_deny_paths, :scope_guard, config: %{deny: []})
      assert ScopeGuard.evaluate(predicate, %{workspace: dir}).status == :pass
    end
  end

  # ===========================================================================
  # 4. the violation appears as failing evidence in the observed iteration
  # ===========================================================================

  describe "the loop observes a deny-path violation as a failing guard (fed back as evidence)" do
    test "an already-violated deny path fails the synthesized guard at observation" do
      dir = git_repo_with(%{"ios/Auth.plist" => "original", "feature.txt" => ""})
      File.write!(Path.join(dir, "ios/Auth.plist"), "an out-of-intent edit")

      [guard] = Scope.guard_predicates(Scope.new(deny: ["ios/Auth.plist"]))
      vector = observe_with_guard(dir, guard)

      result = PredicateVector.get(vector, guard.id)
      assert result.status == :fail
      assert result.evidence.changed == ["ios/Auth.plist"]
    end

    test "an untouched deny path passes the synthesized guard at observation" do
      dir = git_repo_with(%{"ios/Auth.plist" => "original", "feature.txt" => ""})

      [guard] = Scope.guard_predicates(Scope.new(deny: ["ios/Auth.plist"]))
      vector = observe_with_guard(dir, guard)

      assert PredicateVector.get(vector, guard.id).status == :pass
    end
  end

  # ===========================================================================
  # 5. Kazi.Runtime wires the guard automatically from goal.scope.deny
  # ===========================================================================

  describe "Kazi.Runtime.check/2 wires the scope guard automatically" do
    test "a goal declaring [scope].deny gets the guard folded in and the check reports it" do
      dir = git_repo_with(%{"ios/Auth.plist" => "original"})
      File.write!(Path.join(dir, "ios/Auth.plist"), "tampered")

      goal =
        Goal.new("g",
          predicates: [Predicate.new(:code, :custom_script, config: %{cmd: "true"})],
          scope: Scope.new(deny: ["ios/Auth.plist"])
        )

      assert {:ok, %{status: :fail, vector: vector}} =
               Runtime.check(goal,
                 workspace: dir,
                 providers: %{custom_script: CustomScript, scope_guard: ScopeGuard}
               )

      assert PredicateVector.get(vector, :scope_deny_paths).status == :fail
    end

    test "a goal with no declared deny gets no scope guard" do
      dir = git_repo_with(%{"feature.txt" => ""})

      goal =
        Goal.new("g",
          predicates: [Predicate.new(:code, :custom_script, config: %{cmd: "true"})]
        )

      assert {:ok, %{status: :pass, vector: vector}} =
               Runtime.check(goal,
                 workspace: dir,
                 providers: %{custom_script: CustomScript, scope_guard: ScopeGuard}
               )

      assert PredicateVector.get(vector, :scope_deny_paths) == nil
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defmodule ScriptedProvider do
    @behaviour Kazi.PredicateProvider
    use Agent

    def start_link(script), do: Agent.start_link(fn -> script end)

    @impl true
    def evaluate(%Predicate{id: id}, context) do
      pid = context.goal.metadata.script_pid

      status =
        Agent.get_and_update(pid, fn script ->
          case Map.get(script, id, [:pass]) do
            [last] -> {last, script}
            [head | tail] -> {head, Map.put(script, id, tail)}
          end
        end)

      Kazi.PredicateResult.new(status, %{id: id, status: status})
    end
  end

  defmodule NoopHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{output: "ok", cost: %{tokens: 1}}}
  end

  defmodule RecordingIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(_action, _context), do: {:ok, %{pr: 1}}
  end

  defmodule RecordingDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(_action, _context), do: {:ok, %{ref: "v1"}}
  end

  # Drive a single observation of a goal carrying `guard` as its only guard and
  # return the observed predicate vector — the loop's on_iteration seam captures
  # the FIRST observation deterministically (mirrors Kazi.EnforcementTest).
  defp observe_with_guard(dir, guard) do
    test = self()
    {:ok, script} = ScriptedProvider.start_link(%{code: [:fail]})

    goal =
      Goal.new("observe-#{System.unique_integer([:positive])}",
        predicates: [Predicate.new(:code, :tests)],
        guards: [guard],
        metadata: %{script_pid: script}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: ScriptedProvider, scope_guard: ScopeGuard},
        harness: NoopHarness,
        integrate: RecordingIntegrate,
        deploy: RecordingDeploy,
        workspace: dir,
        adapter_opts: [],
        reobserve_interval_ms: 50,
        flake_max_retries: 0,
        stuck_iterations: 0,
        on_iteration: fn payload ->
          send(test, {:observed, payload.iteration, payload.vector})
        end
      )

    assert_receive {:observed, 0, vector}, 5_000
    Kazi.Loop.stop(loop)
    vector
  end

  defp tmp_dir do
    dir =
      Path.join(System.tmp_dir!(), "kazi-scope-guard-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # A real git repo seeded with the given {relative-path => contents} and one
  # commit, so a later edit is measurable as a diff against that commit (the
  # `Kazi.ScopeDiff.base_ref/1` fallback when there is no `origin/main`).
  defp git_repo_with(files) do
    dir = tmp_dir()
    {_, 0} = System.cmd("git", ["init", "--initial-branch=main", dir], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: dir)
    {_, 0} = System.cmd("git", ["config", "commit.gpgsign", "false"], cd: dir)

    Enum.each(files, fn {rel, contents} ->
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)

    {_, 0} = System.cmd("git", ["add", "-A"], cd: dir)
    {_, 0} = System.cmd("git", ["commit", "-m", "seed"], cd: dir, stderr_to_stdout: true)
    dir
  end
end

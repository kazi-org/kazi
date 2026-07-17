defmodule Kazi.EnforcementTest do
  @moduledoc """
  T32.4 anti-gaming enforcement (ADR-0042). Covers every acceptance bullet:

    * a skipped test counts as `:fail`, not `:pass` (guarantee 3);
    * deleting a test trips the count RATCHET (a guard regression, not progress —
      guarantee 4, via the T32.3 machinery);
    * a write to a read-only-leased predicate file is FLAGGED (guarantee 2);
    * the checker runs in a SEPARATE process resolved from a CLEAN tree — an
      in-iteration edit to the checker file does NOT affect the verdict (guarantee
      1, the core anti-gaming guarantee);
    * the active enforcement guarantees appear in the loop's result/snapshot, the
      surface `kazi run --json` renders (guarantee 7);
    * graceful degradation reports the ACTUAL guarantee level (no fabrication).

  Isolation (T59.5, #1025/#1186): the `Loop.await`/`assert_receive` deadlines here
  are generous (30s convergence, 15s observe), not tight. These loops do real work
  -- clean-tree isolation git-COPIES the workspace and the guard runs in a separate
  OS process -- which is genuinely slower to schedule under full-suite load on a
  busy box, so a tight bound reddens a run that WOULD pass. The generous bound is
  still well under ExUnit's 60s per-test timeout, so a true hang still fails; the
  loop's own messages drive the wait, so this is not a Process.sleep.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Enforcement, Goal, Predicate, PredicateResult}
  alias Kazi.Providers.{CustomScript, Ratchet}

  # ===========================================================================
  # Test doubles (zero-stub: behaviours only, scoped to this test)
  # ===========================================================================

  # A scripted provider: pops the next status per predicate id (last status sticks).
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

      PredicateResult.new(status, %{id: id, status: status})
    end
  end

  # A harness that WRITES to a path in the workspace — to prove a read-only-lease
  # write is flagged. The relative path is read from adapter_opts.
  defmodule WritingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(_prompt, workspace, opts) do
      rel = Keyword.fetch!(opts, :write_path)
      File.write!(Path.join(workspace, rel), "tampered-#{System.unique_integer([:positive])}")
      {:ok, %{output: "ok", cost: %{tokens: 1}}}
    end
  end

  # A harness that does nothing (the clean-tree test only needs an observation).
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

  # ===========================================================================
  # Pure profile: resolve + guarantees
  # ===========================================================================

  describe "resolve/1 (default-on for creation, opt-in for repair)" do
    test "a creation-mode goal is enforcement-on by default" do
      assert Enforcement.resolve(Goal.new("g", mode: :create)).enabled
    end

    test "a repair goal is enforcement-off by default (opt-in)" do
      refute Enforcement.resolve(Goal.new("g", mode: :repair)).enabled
    end

    test "an authored profile wins — including an explicit opt-out on a creation goal" do
      profile = Enforcement.new(enabled: false)
      goal = Goal.new("g", mode: :create, enforcement: profile)
      refute Enforcement.resolve(goal).enabled
    end
  end

  describe "guarantee_atoms/1" do
    test "enumerates the configured guarantees of an active profile, sorted" do
      profile =
        Enforcement.new(
          enabled: true,
          read_only_paths: ["test/"],
          guards: [%{id: :c, metric: %{cmd: "x"}}]
        )

      assert Enforcement.guarantee_atoms(profile) ==
               [:clean_tree, :fail_on_skip, :ratchet_guards, :read_only_lease, :separate_process]
    end

    test "an inactive profile has no guarantees" do
      assert Enforcement.guarantee_atoms(Enforcement.new(enabled: false)) == []
      assert Enforcement.guarantee_atoms(nil) == []
    end

    test "separate_process is always present for an active profile (the held rung)" do
      profile = Enforcement.new(enabled: true, clean_tree: false)
      assert :separate_process in Enforcement.guarantee_atoms(profile)
      refute :clean_tree in Enforcement.guarantee_atoms(profile)
    end
  end

  # ===========================================================================
  # (c) skipped / errored / xfail sub-results map to :fail
  # ===========================================================================

  describe "enforce_result/2 — a skipped test counts as :fail not :pass" do
    setup do
      %{profile: Enforcement.new(enabled: true, fail_on_skip: true)}
    end

    test "a structured skipped count downgrades a pass to fail", %{profile: profile} do
      result = PredicateResult.new(:pass, %{skipped: 1})
      assert Enforcement.enforce_result(profile, result).status == :fail
    end

    test "a JUnit <skipped> in the output downgrades a pass to fail", %{profile: profile} do
      junit = ~s(<testsuite><testcase name="t"><skipped/></testcase></testsuite>)
      result = PredicateResult.new(:pass, %{output: junit})
      downgraded = Enforcement.enforce_result(profile, result)
      assert downgraded.status == :fail
      assert downgraded.evidence.enforcement_downgrade == :skipped
    end

    test "an errored sub-result downgrades a pass to fail", %{profile: profile} do
      junit = ~s(<testcase name="t"><error message="boom"/></testcase>)
      result = PredicateResult.new(:pass, %{output: junit})
      assert Enforcement.enforce_result(profile, result).status == :fail
    end

    test "an xfail marker downgrades a pass to fail", %{profile: profile} do
      result = PredicateResult.new(:pass, %{output: "1 passed, 1 xfail"})
      assert Enforcement.enforce_result(profile, result).status == :fail
    end

    test "a clean pass with no skips is untouched", %{profile: profile} do
      result = PredicateResult.new(:pass, %{output: "2 passed"})
      assert Enforcement.enforce_result(profile, result).status == :pass
    end

    test "a genuine fail is untouched (no spurious upgrade)", %{profile: profile} do
      result = PredicateResult.new(:fail, %{output: "1 failed"})
      assert Enforcement.enforce_result(profile, result).status == :fail
    end

    test "an inactive profile leaves a skipped result untouched" do
      result = PredicateResult.new(:pass, %{skipped: 3})
      assert Enforcement.enforce_result(Enforcement.new(enabled: false), result).status == :pass
      assert Enforcement.enforce_result(nil, result).status == :pass
    end
  end

  # ===========================================================================
  # (b) read-only lease: a write to a leased path is flagged
  # ===========================================================================

  describe "digest_paths/2 + detect_writes/3 — a write to a read-only path is flagged" do
    setup do
      dir = tmp_dir()
      File.write!(Path.join(dir, "pred.toml"), "original")
      %{dir: dir}
    end

    test "an unchanged path is not flagged", %{dir: dir} do
      before = Enforcement.digest_paths(dir, ["pred.toml"])
      assert Enforcement.detect_writes(dir, ["pred.toml"], before) == []
    end

    test "a modified leased file is flagged as a read_only_write", %{dir: dir} do
      before = Enforcement.digest_paths(dir, ["pred.toml"])
      File.write!(Path.join(dir, "pred.toml"), "tampered")

      assert [%{type: :read_only_write, path: "pred.toml"}] =
               Enforcement.detect_writes(dir, ["pred.toml"], before)
    end

    test "a new file under a leased directory is flagged", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "test"))
      File.write!(Path.join(dir, "test/a_test.exs"), "one")
      before = Enforcement.digest_paths(dir, ["test"])
      File.write!(Path.join(dir, "test/b_test.exs"), "two")

      assert [%{type: :read_only_write, path: "test"}] =
               Enforcement.detect_writes(dir, ["test"], before)
    end
  end

  test "the loop flags a fixer agent writing a read-only-leased predicate file" do
    dir = git_repo_with(%{"pred.toml" => "original", "feature.txt" => ""})

    profile =
      Enforcement.new(
        enabled: true,
        clean_tree: false,
        read_only_paths: ["pred.toml"]
      )

    # The code predicate is failing then passing so the loop dispatches ONCE (the
    # WritingHarness tampers pred.toml during that dispatch) and then converges.
    {:ok, script} = ScriptedProvider.start_link(%{code: [:fail, :pass]})

    goal =
      Goal.new("ro-lease",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{script_pid: script}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: ScriptedProvider},
        harness: WritingHarness,
        integrate: RecordingIntegrate,
        deploy: RecordingDeploy,
        workspace: dir,
        adapter_opts: [write_path: "pred.toml"],
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0,
        enforcement: profile
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 30_000)
    assert result.outcome == :converged

    assert [%{type: :read_only_write, path: "pred.toml"} | _] = result.enforcement.gaming_events
    assert result.enforcement.active
  end

  # ===========================================================================
  # (d) deleting a test trips the count ratchet (guard regression, not progress)
  # ===========================================================================

  test "guard_predicates/1 synthesizes a :ratchet guard from a declared guard config" do
    profile =
      Enforcement.new(
        enabled: true,
        guards: [%{id: :test_count, metric: %{cmd: "sh"}, direction: :higher_better}]
      )

    assert [%Predicate{id: :test_count, kind: :ratchet, guard?: true} = guard] =
             Enforcement.guard_predicates(profile)

    assert guard.config.baseline == "stored"
    assert guard.config.allowed_regression == 0
  end

  test "deleting a test trips the count ratchet guard (regression, not progress)" do
    dir = tmp_dir()
    store = tmp_dir()
    File.write!(Path.join(dir, "a_test.txt"), "")
    File.write!(Path.join(dir, "b_test.txt"), "")
    File.write!(Path.join(dir, "c_test.txt"), "")

    profile =
      Enforcement.new(
        enabled: true,
        guards: [
          %{
            id: "test_count",
            # Count the *_test.txt files — a stand-in for "how many tests exist".
            metric: %{cmd: "sh", args: ["-c", "ls *_test.txt | wc -l"]},
            direction: "higher_better",
            baseline: "stored",
            allowed_regression: 0
          }
        ]
      )

    [guard] = Enforcement.guard_predicates(profile)
    context = %{workspace: dir, ratchet_store_dir: store}

    # First run SEEDS the baseline at 3 (passes — nothing to regress from yet).
    seed = Ratchet.evaluate(guard, context)
    assert seed.status == :pass
    assert seed.evidence.baseline_source == :seed

    # The agent deletes a test: the count drops to 2 — a guard REGRESSION.
    File.rm!(Path.join(dir, "c_test.txt"))
    regressed = Ratchet.evaluate(guard, context)

    assert regressed.status == :fail
    assert regressed.score == 2.0
  end

  # ===========================================================================
  # (a) clean-tree + separate-process: an in-iteration checker edit does NOT
  #     change the verdict — the core anti-gaming guarantee.
  # ===========================================================================

  test "an edit to a GRADER-declared checker file does NOT change an isolated guard's verdict" do
    # A committed checker that PASSES (exit 0). The guard runs it. `check.sh` is
    # declared as a `read_only_paths` grader-definition file (H1 fix, deep-review
    # 001: clean-tree isolation pins ONLY the declared grader paths to `ref`, not
    # the whole cwd — see isolation.ex moduledoc), so it stays protected.
    dir = git_repo_with(%{"check.sh" => "exit 0\n", "feature.txt" => ""})

    # The agent (between observations) TAMPERS the checker in the working copy to
    # make it fail — the classic "edit the grader" exploit.
    File.write!(Path.join(dir, "check.sh"), "exit 1\n")

    guard =
      Predicate.new(:grader, :custom_script,
        guard?: true,
        config: %{cmd: "sh", args: ["check.sh"], verdict: "exit_zero"}
      )

    # WITH enforcement clean-tree + check.sh declared read-only: the guard is
    # resolved from the CLEAN tree (HEAD) for its OWN grader path, so the
    # working-copy tamper is invisible — it still PASSES.
    isolated =
      observe_guard_verdict(
        dir,
        guard,
        Enforcement.new(enabled: true, clean_tree: true, read_only_paths: ["check.sh"])
      )

    assert isolated == :pass

    # WITHOUT clean-tree isolation: the guard runs the TAMPERED working copy → fail.
    # (This is exactly the gaming the isolation closes.)
    unisolated =
      observe_guard_verdict(dir, guard, Enforcement.new(enabled: true, clean_tree: false))

    assert unisolated == :fail
  end

  test "clean-tree isolation degrades gracefully + reports the actual guarantee level" do
    # A NON-git workspace: clean-tree cannot be established. The checker still runs
    # (against the working copy) and the reported guarantees DROP :clean_tree —
    # honesty, never a fabricated guarantee.
    dir = tmp_dir()
    File.write!(Path.join(dir, "check.sh"), "exit 0\n")

    guard =
      Predicate.new(:grader, :custom_script,
        guard?: true,
        config: %{cmd: "sh", args: ["check.sh"], verdict: "exit_zero"}
      )

    {verdict, enforcement} =
      observe_guard(dir, guard, Enforcement.new(enabled: true, clean_tree: true))

    # The checker ran (against the working copy) — it did not error out.
    assert verdict == :pass
    # Honest reporting: clean_tree is NOT among the active guarantees (it degraded),
    # but separate_process (the held rung) still is.
    refute :clean_tree in enforcement.guarantees
    assert :separate_process in enforcement.guarantees
  end

  # ===========================================================================
  # (e) the active enforcement guarantees appear in the result/snapshot --json
  # ===========================================================================

  test "the active enforcement guarantees are surfaced in the loop result" do
    dir = git_repo_with(%{"check.sh" => "exit 0\n", "feature.txt" => ""})
    {:ok, script} = ScriptedProvider.start_link(%{code: [:fail, :pass]})

    guard =
      Predicate.new(:grader, :custom_script,
        guard?: true,
        config: %{cmd: "sh", args: ["check.sh"], verdict: "exit_zero"}
      )

    goal =
      Goal.new("guarantees",
        predicates: [Predicate.new(:code, :tests)],
        guards: [guard],
        metadata: %{script_pid: script}
      )

    profile =
      Enforcement.new(
        enabled: true,
        clean_tree: true,
        read_only_paths: ["check.sh"],
        guards: [%{id: :ignored, metric: %{cmd: "x"}}]
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: ScriptedProvider, custom_script: CustomScript},
        harness: NoopHarness,
        integrate: RecordingIntegrate,
        deploy: RecordingDeploy,
        workspace: dir,
        adapter_opts: [],
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0,
        enforcement: profile
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 30_000)
    assert result.enforcement.active
    # The full active set, including clean_tree (the workspace IS a git repo).
    assert :clean_tree in result.enforcement.guarantees
    assert :separate_process in result.enforcement.guarantees
    assert :read_only_lease in result.enforcement.guarantees
    assert :ratchet_guards in result.enforcement.guarantees
  end

  test "enforcement is off by default for a non-enforcement loop (no behaviour change)" do
    {:ok, script} = ScriptedProvider.start_link(%{code: [:pass]})

    goal =
      Goal.new("no-enforce",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{script_pid: script}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: ScriptedProvider},
        harness: NoopHarness,
        integrate: RecordingIntegrate,
        deploy: RecordingDeploy,
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 30_000)
    refute result.enforcement.active
    assert result.enforcement.guarantees == []
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  # Drive a single observation of a goal carrying one isolated guard and return
  # that guard's verdict in the enforced vector — the loop's on_iteration seam
  # captures the FIRST observation deterministically.
  defp observe_guard_verdict(dir, guard, profile) do
    {verdict, _enforcement} = observe_guard(dir, guard, profile)
    verdict
  end

  defp observe_guard(dir, guard, profile) do
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
        providers: %{tests: ScriptedProvider, custom_script: CustomScript},
        harness: NoopHarness,
        integrate: RecordingIntegrate,
        deploy: RecordingDeploy,
        workspace: dir,
        adapter_opts: [],
        reobserve_interval_ms: 50,
        flake_max_retries: 0,
        stuck_iterations: 0,
        enforcement: profile,
        on_iteration: fn payload ->
          send(test, {:observed, payload.iteration, payload.vector})
        end
      )

    assert_receive {:observed, 0, vector}, 15_000
    enforcement = Kazi.Loop.snapshot(loop).enforcement
    Kazi.Loop.stop(loop)

    {Kazi.PredicateVector.get(vector, guard.id).status, enforcement}
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "kazi-enforce-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # A real git repo seeded with the given {relative-path => contents} and one
  # commit, so HEAD is a clean tree the enforcement isolation can check out.
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

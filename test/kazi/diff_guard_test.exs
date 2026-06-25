defmodule Kazi.DiffGuardTest do
  @moduledoc """
  T32.5 diff-inspection gaming guard (ADR-0042 §5, ADVISORY). Covers every
  acceptance bullet:

    * a diff that adds a `skip`/`xfail` marker is FLAGGED with evidence;
    * a diff that special-cases a known test input is FLAGGED with evidence;
    * a diff that edits a grader/predicate path is FLAGGED;
    * a legitimate refactor diff is NOT flagged (the low-false-positive bar);
    * at the loop level the flag DOWNGRADES progress (a GAMED apparent score
      improvement no longer rescues the loop from the stuck detector) and does NOT
      crash the loop, while NEVER blocking a genuine convergence.
  """
  use ExUnit.Case, async: true

  alias Kazi.Enforcement.DiffGuard
  alias Kazi.{Action, Goal, Predicate, PredicateResult}

  doctest Kazi.Enforcement.DiffGuard

  # ===========================================================================
  # Pure scanner: signatures fire with evidence
  # ===========================================================================

  describe "scan/2 — skip/xfail markers (newly added)" do
    test "a newly-added @pytest.mark.skip is flagged with file + line + snippet" do
      diff = """
      diff --git a/test_widget.py b/test_widget.py
      --- a/test_widget.py
      +++ b/test_widget.py
      @@ -1,2 +1,3 @@
       def test_one():
      +    @pytest.mark.skip(reason="flaky")
           assert foo() == 1
      """

      assert [event] = DiffGuard.scan(diff)
      assert event.type == :diff_gaming
      assert event.signature == :skip_marker
      assert event.file == "test_widget.py"
      assert event.line == 2
      assert event.snippet =~ "@pytest.mark.skip"
    end

    test "skip/xfail/ignore markers across runners are each detected" do
      lines = [
        "@pytest.mark.xfail",
        "pytest.skip(\"todo\")",
        "@unittest.skip(\"wip\")",
        "self.skipTest(\"later\")",
        "raise SkipTest",
        "it.skip(\"pending\", () => {})",
        "xit(\"pending\", () => {})",
        "t.Skip(\"flaky\")",
        "#[ignore]",
        "@Disabled",
        "@tag :skip"
      ]

      for marker <- lines do
        diff = "+++ b/test_x\n@@ -0,0 +1 @@\n+#{marker}\n"
        assert [%{signature: :skip_marker}] = DiffGuard.scan(diff), "expected flag for #{marker}"
      end
    end

    test "a REMOVED skip marker (un-skipping) is NOT flagged" do
      diff = """
      +++ b/test_widget.py
      @@ -1,2 +1,1 @@
      -    @pytest.mark.skip
       def test_one(): pass
      """

      assert DiffGuard.scan(diff) == []
    end
  end

  describe "scan/2 — test-input special-casing" do
    test "an added `if input == <literal>` branch is flagged" do
      diff = """
      +++ b/lib/solver.py
      @@ -1,1 +1,3 @@
       def solve(input):
      +    if input == "case_42":
      +        return 99
      """

      assert [event] = DiffGuard.scan(diff)
      assert event.signature == :test_special_casing
      assert event.snippet =~ "case_42"
    end

    test "an added numeric special-case is flagged" do
      diff = "+++ b/lib/solver.py\n@@ -0,0 +1 @@\n+    if n == 1000000: return 42\n"
      assert [%{signature: :test_special_casing}] = DiffGuard.scan(diff)
    end

    test "an ordinary `if mode == \"create\"` branch is NOT flagged (low false-positive)" do
      diff = """
      +++ b/lib/runtime.ex
      @@ -0,0 +1,2 @@
      +    if mode == "create" do
      +      enable_enforcement()
      """

      assert DiffGuard.scan(diff) == []
    end
  end

  describe "scan/2 — grader / predicate edits" do
    test "a change to a configured grader path is flagged" do
      diff = """
      +++ b/predicates.toml
      @@ -1,1 +1,1 @@
      -threshold = 0.9
      +threshold = 0.0
      """

      assert [event] = DiffGuard.scan(diff, grader_paths: ["predicates.toml"])
      assert event.signature == :grader_edit
      assert event.file == "predicates.toml"
    end

    test "a change under a leased grader DIRECTORY is flagged" do
      diff = "+++ b/test/acceptance/check.exs\n@@ -0,0 +1 @@\n+assert true\n"
      assert [_ | _] = events = DiffGuard.scan(diff, grader_paths: ["test/acceptance"])
      assert Enum.any?(events, &(&1.signature == :grader_edit))
    end

    test "an obviously-named predicate file is flagged by the built-in heuristic" do
      diff = "+++ b/ship.goal.toml\n@@ -0,0 +1 @@\n+enabled = false\n"
      assert [%{signature: :grader_edit}] = DiffGuard.scan(diff)
    end

    test "an ordinary source file is NOT treated as a grader" do
      diff = "+++ b/lib/widget.ex\n@@ -0,0 +1 @@\n+  def add(a, b), do: a + b\n"
      assert DiffGuard.scan(diff) == []
    end
  end

  describe "scan/2 — a legitimate refactor is not flagged" do
    test "a whitespace/rename refactor diff yields no events" do
      diff = """
      diff --git a/lib/widget.py b/lib/widget.py
      --- a/lib/widget.py
      +++ b/lib/widget.py
      @@ -1,4 +1,4 @@
      -def add(a,b):
      -    return a+b
      +def add(a, b):
      +    return a + b
       # widget helpers
       value = compute()
      """

      assert DiffGuard.scan(diff) == []
    end

    test "an empty / non-binary diff is a no-op" do
      assert DiffGuard.scan("") == []
      assert DiffGuard.scan(nil) == []
    end
  end

  # ===========================================================================
  # Loop level: the flag downgrades progress without crashing or blocking
  # ===========================================================================

  # A provider that ALWAYS fails but reports a steadily IMPROVING score. Without the
  # diff guard this reads as "progressing" (the ADR-0041 graded-score escape), so
  # the stuck detector never fires; with the guard discounting a gamed iteration's
  # score, the apparent progress is not credited.
  defmodule ImprovingButFailingProvider do
    @behaviour Kazi.PredicateProvider
    use Agent

    def start_link, do: Agent.start_link(fn -> 0 end)

    @impl true
    def evaluate(%Predicate{id: id}, context) do
      pid = context.goal.metadata.score_pid
      n = Agent.get_and_update(pid, fn n -> {n, n + 1} end)
      PredicateResult.new(:fail, %{id: id}, score: n * 1.0, direction: :higher_better)
    end
  end

  # A provider scripted fail→pass (last status sticks) — to prove the advisory guard
  # never blocks a genuine convergence.
  defmodule ConvergingProvider do
    @behaviour Kazi.PredicateProvider
    @impl true
    def evaluate(%Predicate{id: id}, context) do
      pid = context.goal.metadata.conv_pid

      status =
        Agent.get_and_update(pid, fn
          [last] -> {last, [last]}
          [head | tail] -> {head, tail}
        end)

      PredicateResult.new(status, %{id: id})
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

  @gaming_diff "+++ b/test_widget.py\n@@ -0,0 +1 @@\n+    @pytest.mark.skip\n"
  @benign_diff "+++ b/lib/widget.py\n@@ -0,0 +1 @@\n+    return a + b\n"

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "kazi-diff-guard-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp start_loop(diff, opts) do
    {:ok, score_pid} = ImprovingButFailingProvider.start_link()

    goal =
      Goal.new("diff-guard",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{score_pid: score_pid}
      )

    base = [
      goal: goal,
      providers: %{tests: ImprovingButFailingProvider},
      harness: NoopHarness,
      integrate: RecordingIntegrate,
      deploy: RecordingDeploy,
      workspace: tmp_dir(),
      enforcement: Kazi.Enforcement.new(enabled: true, clean_tree: false),
      diff_fn: fn _ws -> diff end,
      reobserve_interval_ms: 1,
      flake_max_retries: 0
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  test "a gaming diff is flagged with evidence and DOWNGRADES progress (stuck fires)" do
    {:ok, loop} = start_loop(@gaming_diff, stuck_iterations: 3, on_escalation: fn _ -> :ok end)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)

    # Progress downgraded: the gamed score improvement is not credited, so the loop
    # stops STUCK rather than running on a fake gradient. It did NOT crash.
    assert result.outcome == :stopped
    assert result.reason == :stuck

    # Flagged with evidence, surfaced in the enforcement status (the --json surface).
    assert result.enforcement.active

    assert Enum.any?(result.enforcement.gaming_events, fn e ->
             e.type == :diff_gaming and e.signature == :skip_marker
           end)
  end

  test "a legitimate refactor diff is NOT flagged — the improving score keeps progressing" do
    {:ok, loop} = start_loop(@benign_diff, stuck_iterations: 3, on_escalation: fn _ -> :ok end)

    # No flag → the graded-score escape stands → the loop is progressing, not stuck:
    # await times out and it is still running.
    assert {:error, :timeout} = Kazi.Loop.await(loop, 200)

    snap = Kazi.Loop.snapshot(loop)
    refute snap.state == :stopped
    assert snap.enforcement.gaming_events == []

    :ok = Kazi.Loop.stop(loop)
  end

  test "the diff guard never blocks a genuine convergence" do
    # The predicate converges (fail then pass) even though every dispatch's diff
    # carries a gaming signature: the advisory guard surfaces the event but the
    # boolean failing-set/convergence logic is untouched.
    {:ok, script} = Agent.start_link(fn -> [:fail, :pass] end)

    goal =
      Goal.new("diff-guard-converge",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{conv_pid: script}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: ConvergingProvider},
        harness: NoopHarness,
        integrate: RecordingIntegrate,
        deploy: RecordingDeploy,
        workspace: tmp_dir(),
        enforcement: Kazi.Enforcement.new(enabled: true, clean_tree: false),
        diff_fn: fn _ws -> @gaming_diff end,
        reobserve_interval_ms: 1,
        flake_max_retries: 0,
        stuck_iterations: 0
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :converged
    # The event was still surfaced (advisory) even though convergence proceeded.
    assert Enum.any?(result.enforcement.gaming_events, &(&1.signature == :skip_marker))
  end
end

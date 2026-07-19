defmodule Kazi.Loop.PriorScoreThreadTest do
  @moduledoc """
  Loop-level enforcement of the envelope-v2 gradient (ADR-0041 / T32.2): the loop
  THREADS each predicate's previous-iteration score into `prior_score`, and the
  stuck-detector reads the direction-interpreted delta — so a loop steadily
  shrinking a `:lower_better` count is NOT escalated as stuck while it is making
  progress, even though its failing SET never changes.

  The pure threading and the graded-score escape are unit-tested in
  `Kazi.PredicateResultTest` and `Kazi.Loop.StuckDetectorTest`; here we prove the
  running loop wires them together.
  """
  use ExUnit.Case, async: false

  alias Kazi.{Action, Goal, Predicate, PredicateResult, PredicateVector}

  # A provider whose predicate is ALWAYS :fail (constant failing set) but whose
  # `:lower_better` score DESCENDS 30,25,20,...,0 then PLATEAUS at 0. While the
  # score falls the loop is progressing; once it plateaus the gradient is flat and
  # the loop is genuinely stuck. The call counter lives in an Agent keyed by the
  # module name so the stateless provider can read it.
  defmodule DescendingScoreProvider do
    @behaviour Kazi.PredicateProvider

    @impl true
    def evaluate(%Predicate{id: id}, _context) do
      n = Agent.get_and_update(__MODULE__, fn c -> {c, c + 1} end)
      score = max(30 - n * 5, 0) * 1.0
      PredicateResult.new(:fail, %{id: id}, score: score, direction: :lower_better)
    end
  end

  defmodule NoopHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(_prompt, _workspace, _opts), do: {:ok, %{output: "ok"}}
  end

  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  setup do
    {:ok, _} = Agent.start_link(fn -> 0 end, name: DescendingScoreProvider)
    :ok
  end

  defp start_loop(opts) do
    base = [
      goal: Goal.new("graded-stuck", predicates: [Predicate.new(:code, :tests)]),
      providers: %{tests: DescendingScoreProvider},
      harness: NoopHarness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      reobserve_interval_ms: 1,
      flake_max_retries: 0
    ]

    Kazi.Loop.start_link(Keyword.merge(base, opts))
  end

  test "the loop threads prior_score: each iteration's prior is the last iteration's score" do
    test_pid = self()

    {:ok, _loop} =
      start_loop(
        stuck_iterations: 3,
        on_escalation: fn _ -> :ok end,
        on_iteration: fn payload -> send(test_pid, {:iter, payload.iteration, payload.vector}) end
      )

    # Collect the first three observations' vectors.
    vectors =
      for i <- 0..2 do
        assert_receive {:iter, ^i, vector}, 1_000
        vector
      end

    [v0, v1, v2] = Enum.map(vectors, fn v -> PredicateVector.get(v, :code) end)

    # Iteration 0 has no prior; 1's prior is 0's score; 2's prior is 1's score.
    assert v0.score == 30.0
    assert v0.prior_score == nil

    assert v1.score == 25.0
    assert v1.prior_score == 30.0
    assert PredicateResult.progress(v1) == :progressed

    assert v2.score == 20.0
    assert v2.prior_score == 25.0
    assert PredicateResult.progress(v2) == :progressed
  end

  test "a descending score delays the stuck stop past the boolean window, then stops on the plateau" do
    {:ok, loop} = start_loop(stuck_iterations: 3, on_escalation: fn _ -> :ok end)

    assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
    assert result.outcome == :stopped
    assert result.reason == :stuck

    # A boolean (no-score) provider with this same constant failing set stops at
    # exactly 3 iterations (see Kazi.StuckLoopTest). The descending score keeps the
    # loop progressing until the score plateaus at 0: scores 30,25,20,15,10,5,0,0,0
    # — the first all-flat window is the last three, so the loop runs 9 iterations.
    assert result.iterations == 9
    assert Kazi.Loop.snapshot(loop).stuck_failing == [:code]
  end
end

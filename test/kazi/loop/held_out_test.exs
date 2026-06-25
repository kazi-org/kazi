defmodule Kazi.Loop.HeldOutTest do
  @moduledoc """
  T32.6 (ADR-0042 §6): the optional held-out acceptance subset — the
  visible-for-iteration vs hidden-for-acceptance split.

  A predicate marked `held_out = true` is STILL evaluated by the controller and
  STILL gates convergence (`:converged` requires the whole vector `:pass`,
  ADR-0002), but its id/definition/evidence are withheld from the agent's
  dispatch context. A capable agent can game only what it can see (METR's 43x
  reward-hacking finding, ADR-0042 context), so withholding the acceptance subset
  keeps the bar honest.

  These tests drive a real dispatch through `Kazi.Loop` and capture the exact
  prompt the harness receives plus the observe vector each iteration, asserting:

    * a held-out predicate's id + evidence are ABSENT from the dispatch prompt,
      while the visible predicate's id + evidence ARE present (it still seeds the
      fix context);
    * the held-out predicate IS present in the observe vector every iteration;
    * `:converged` requires the held-out predicate to pass — a loop whose visible
      predicate is already green does NOT converge while the held-out one fails,
      and converges only once it passes;
    * even when the held-out predicate is the SOLE failing predicate, its id is
      never named in the dispatch prompt.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate, PredicateVector}

  # A code predicate provider scripted per id: pops the next status, holding the
  # last forever, and emits per-id evidence ("boom in <id>") so a test can assert
  # a specific predicate's evidence is present or absent in the dispatch prompt.
  defmodule ScriptedProvider do
    @behaviour Kazi.PredicateProvider
    use Agent

    def start_link(script) when is_map(script), do: Agent.start_link(fn -> script end)

    @impl true
    def evaluate(%Predicate{id: id}, context) do
      pid = context.goal.metadata.script_pid

      status =
        Agent.get_and_update(pid, fn script ->
          case Map.get(script, id, [:pass]) do
            [last] -> {last, %{script | id => [last]}}
            [next | rest] -> {next, %{script | id => rest}}
          end
        end)

      Kazi.PredicateResult.new(status, %{output: "boom in #{id}"})
    end
  end

  # Harness double: forwards every dispatch prompt to the collector pid so the
  # test can inspect the exact text `dispatch_prompt/2` produced.
  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(prompt, _workspace, opts) do
      send(Keyword.fetch!(opts, :collector), {:dispatched, prompt})
      {:ok, %{output: "ok", cost: %{tokens: 1}, touched: []}}
    end
  end

  # Trivial integrate/deploy doubles so the loop can reach convergence once the
  # code predicates go green (the loop requires both actions before :converged).
  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  defp goal(script_pid) do
    Goal.new("held-out-goal",
      predicates: [
        Predicate.new(:visible, :tests),
        # The acceptance predicate the controller must satisfy but the agent
        # never sees (held_out, ADR-0042 §6).
        Predicate.new(:gold, :tests, acceptance?: true, held_out?: true)
      ],
      metadata: %{script_pid: script_pid}
    )
  end

  # Start a loop, capturing every dispatch prompt and every observe vector via the
  # collector pid (self()). Returns the terminal result.
  defp run_loop(script) do
    {:ok, script_pid} = ScriptedProvider.start_link(script)
    collector = self()

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal(script_pid),
        providers: %{tests: ScriptedProvider},
        harness: RecordingHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        workspace: "/fixture/ws",
        adapter_opts: [collector: collector],
        on_iteration: fn %{vector: vector} -> send(collector, {:observed, vector}) end,
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0
      )

    {:ok, result} = Kazi.Loop.await(loop, 5_000)
    result
  end

  # Drain all collected vectors from the mailbox into a list (oldest first).
  defp collected_vectors(acc \\ []) do
    receive do
      {:observed, vector} -> collected_vectors([vector | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "a held-out predicate is hidden from the agent but enforced by the controller" do
    test "absent from the dispatch prompt; the visible predicate (id + evidence) is present" do
      # Both fail on the first observe, so the first dispatch carries the failing
      # work-list. The held-out `gold` predicate must NOT appear; the visible one
      # (id + its evidence) MUST — it still seeds the fix context.
      _result = run_loop(%{visible: [:fail, :pass], gold: [:fail, :fail, :pass]})

      assert_received {:dispatched, prompt}

      # The visible predicate seeds the fix context: its id and evidence are present.
      assert prompt =~ "fix failing predicates: visible"
      assert prompt =~ "boom in visible"

      # The held-out predicate is withheld entirely: neither its id nor its
      # evidence leaks into the dispatch context (prompt body, orientation, or
      # retrieval — all derived from the same filtered failing slice).
      refute prompt =~ "gold"
      refute prompt =~ "boom in gold"
    end

    test "the held-out predicate IS present in the observe vector every iteration" do
      _result = run_loop(%{visible: [:fail, :pass], gold: [:fail, :fail, :pass]})

      vectors = collected_vectors()
      assert vectors != []

      # The controller evaluates the held-out predicate every observation — it is
      # only hidden from the AGENT, never dropped from the observe vector.
      for vector <- vectors do
        assert PredicateVector.get(vector, :gold) != nil
      end
    end

    test ":converged requires the held-out predicate to pass" do
      # The visible predicate is green from t0; ONLY the held-out predicate is
      # failing. The loop must keep working (it cannot converge while a held-out
      # acceptance predicate fails) and converge only once it passes.
      result = run_loop(%{visible: [:pass], gold: [:fail, :fail, :pass]})

      assert result.outcome == :converged
      assert PredicateVector.get(result.vector, :gold).status == :pass
      assert PredicateVector.get(result.vector, :visible).status == :pass

      # Convergence could not have happened at the first observation: the held-out
      # predicate gated it, forcing further iterations.
      assert result.iterations >= 2

      vectors = collected_vectors()

      refute Enum.empty?(vectors)

      # The FIRST observation had the held-out predicate failing — so the loop did
      # NOT converge on it; the whole-vector gate held the bar.
      first = List.first(vectors)
      assert PredicateVector.get(first, :gold).status == :fail
    end

    test "even when held-out is the SOLE failing predicate its id is never named in the prompt" do
      # Visible is green; the only failing predicate is the held-out one. The loop
      # still dispatches (a code predicate is failing), but with the held-out id
      # filtered out the work-list is empty — the agent is never told about it.
      _result = run_loop(%{visible: [:pass], gold: [:fail, :fail, :pass]})

      assert_received {:dispatched, prompt}

      refute prompt =~ "gold"
      refute prompt =~ "boom in gold"
      # The work-item line is present but its failing list is empty (held-out
      # filtered): the agent sees the goal, not the hidden acceptance predicate.
      assert prompt =~ "fix failing predicates:"
    end
  end
end

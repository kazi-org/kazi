defmodule Kazi.Loop.DebriefTest do
  @moduledoc """
  T48.11 (ADR-0058 §3): the opt-in post-dispatch debrief at the `Kazi.Loop`
  level. Proves, against the REAL loop (not a mock of it):

    * disabled (default) — the dispatch prompt and the `on_iteration` payload's
      `:debrief` field are BYTE-IDENTICAL to a pre-T48.11 loop;
    * enabled — the dispatch prompt carries the fixed debrief question, and a
      scripted harness result's fenced debrief block is parsed, capped, and
      surfaced on the FOLLOWING iteration event (never read back into a later
      prompt — the write-only rule; see `record_debrief/2` in `Kazi.Loop`).
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate, PredicateResult}

  # A predicate provider backed by an Agent returning a scripted sequence of
  # statuses. Mirrors `Kazi.LoopTest.ScriptedProvider` but is local to this file
  # (test doubles are not shared library code, per the zero-stub policy).
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
            [last] -> {last, script}
            [head | tail] -> {head, Map.put(script, id, tail)}
          end
        end)

      PredicateResult.new(status, %{id: id, status: status})
    end
  end

  # Harness double: records each dispatch prompt to the collector and returns a
  # FIXED reply (whatever the test configures via adapter_opts). Configurable
  # output lets a test simulate the agent's structured debrief answer.
  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(prompt, workspace, opts) do
      collector = Keyword.fetch!(opts, :collector)
      output = Keyword.get(opts, :output, "ok")
      send(collector, {:dispatched, prompt, workspace})
      {:ok, %{output: output, cost: %{tokens: 1}}}
    end
  end

  defp start_scripted(script) do
    {:ok, pid} = ScriptedProvider.start_link(script)
    pid
  end

  defp start_loop(goal, collector, opts) do
    base = [
      goal: goal,
      providers: %{tests: ScriptedProvider},
      harness: RecordingHarness,
      integrate: __MODULE__.NoopAction,
      deploy: __MODULE__.NoopAction,
      adapter_opts: [collector: collector, output: Keyword.get(opts, :output, "ok")],
      reobserve_interval_ms: 5,
      flake_max_retries: 0,
      stuck_iterations: 0,
      on_iteration: fn payload -> send(collector, {:iteration, payload}) end
    ]

    Kazi.Loop.start_link(Keyword.merge(base, Keyword.drop(opts, [:output])))
  end

  defmodule NoopAction do
    @behaviour Kazi.Action

    @impl true
    def execute(_action, _context), do: {:ok, %{}}
  end

  defp goal_with(script_pid) do
    Goal.new("loop-debrief-test",
      predicates: [Predicate.new(:code, :tests)],
      metadata: %{script_pid: script_pid}
    )
  end

  @fenced_debrief ~s"""
  Fixed the failing test.

  ```json
  {"debrief": {"needed_but_discovered": ["lib/foo.ex config schema", "the retry convention"]}}
  ```
  """

  describe "disabled (default) — byte-identical to pre-T48.11" do
    test "the dispatch prompt carries no debrief section" do
      script_pid = start_scripted(%{code: [:fail, :pass]})
      goal = goal_with(script_pid)

      {:ok, loop} = start_loop(goal, self(), [])

      assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
      assert result.outcome == :converged

      assert_received {:dispatched, prompt, _ws}
      refute prompt =~ "Debrief"
      refute prompt =~ "needed_but_discovered"
    end

    test "the on_iteration payload's :debrief field is always []" do
      script_pid = start_scripted(%{code: [:fail, :pass]})
      goal = goal_with(script_pid)

      {:ok, loop} = start_loop(goal, self(), output: @fenced_debrief)

      assert {:ok, _result} = Kazi.Loop.await(loop, 5_000)

      # Every iteration event this run emitted — including the one AFTER the
      # dispatch whose harness result actually contained a fenced debrief
      # block — carries an empty list: disabled means the extraction path is
      # never even invoked.
      payloads = collect_iteration_payloads()
      assert payloads != []
      assert Enum.all?(payloads, &(&1.debrief == []))
    end
  end

  describe "enabled (`debrief: true` loop opt)" do
    test "the dispatch prompt carries the fixed debrief question" do
      script_pid = start_scripted(%{code: [:fail, :pass]})
      goal = goal_with(script_pid)

      {:ok, loop} = start_loop(goal, self(), debrief: true)

      assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
      assert result.outcome == :converged

      assert_received {:dispatched, prompt, _ws}
      assert prompt =~ "## Debrief"
      assert prompt =~ "needed_but_discovered"
      # The question is the LAST section of the prompt (appended after
      # retrieval — see `Kazi.Loop.assemble_prompt/1`).
      assert String.ends_with?(String.trim_trailing(prompt), "```")
    end

    test "a scripted harness result's fenced debrief block is parsed, capped, and surfaces on the NEXT iteration event" do
      script_pid = start_scripted(%{code: [:fail, :pass]})
      goal = goal_with(script_pid)

      {:ok, loop} = start_loop(goal, self(), debrief: true, output: @fenced_debrief)

      assert {:ok, _result} = Kazi.Loop.await(loop, 5_000)

      payloads = collect_iteration_payloads()
      # At least one observation after the dispatch carries the capped items.
      assert Enum.any?(payloads, fn p ->
               p.debrief == ["lib/foo.ex config schema", "the retry convention"]
             end)
    end

    test "a plain reply with no fenced block surfaces an empty debrief list, never an error" do
      script_pid = start_scripted(%{code: [:fail, :pass]})
      goal = goal_with(script_pid)

      {:ok, loop} = start_loop(goal, self(), debrief: true, output: "just fixed it, no json here")

      assert {:ok, result} = Kazi.Loop.await(loop, 5_000)
      assert result.outcome == :converged

      payloads = collect_iteration_payloads()
      assert Enum.all?(payloads, &(&1.debrief == []))
    end
  end

  defp collect_iteration_payloads(acc \\ []) do
    receive do
      {:iteration, payload} -> collect_iteration_payloads([payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

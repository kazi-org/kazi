defmodule Kazi.Loop.TaskBriefPromptTest do
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate, Scope}

  defmodule ScriptedProvider do
    @behaviour Kazi.PredicateProvider
    use Agent
    def start_link(script), do: Agent.start_link(fn -> script end)
    @impl true
    def evaluate(%Predicate{id: id}, context) do
      status =
        Agent.get_and_update(context.goal.metadata.script_pid, fn script ->
          case Map.fetch!(script, id) do
            [last] -> {last, script}
            [next | rest] -> {next, Map.put(script, id, rest)}
          end
        end)

      Kazi.PredicateResult.new(status, %{output: "failure evidence"})
    end
  end

  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter
    @impl true
    def run(prompt, _workspace, opts) do
      send(Keyword.fetch!(opts, :collector), {:dispatched, prompt})
      {:ok, %{output: "ok", cost: %{tokens: 1}}}
    end
  end

  defmodule NoopIntegrate do
    @behaviour Kazi.Action
    @impl true
    def execute(_, _), do: {:ok, %{pr: 1}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(_, _), do: {:ok, %{ref: "v1"}}
  end

  for tier <- [0, 2] do
    test "tier #{tier} retains the full declared task after its first predicate passes" do
      {:ok, pid} =
        ScriptedProvider.start_link(%{
          brief: [:fail, :pass, :pass],
          code: [:fail, :fail, :pass],
          guard: [:pass],
          hidden: [:pass]
        })

      on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)

      goal =
        Goal.new("task-contract-test",
          name: "Repair the widget",
          description: "Preserve the public widget behavior.",
          predicates: [
            Predicate.new(:brief, :tests,
              description: "TASK_BRIEF_SENTINEL: implement Widget; touch lib/widget.ex."
            ),
            Predicate.new(:code, :tests,
              description: "CODE_REQUIREMENT_SENTINEL",
              config: %{cmd: "mix", args: ["test", "test/widget_test.exs"]}
            ),
            Predicate.new(:hidden, :tests,
              description: "HIDDEN_REQUIREMENT_SENTINEL",
              config: %{cmd: "hidden-check-command"},
              held_out?: true
            )
          ],
          guards: [
            Predicate.new(:guard, :tests,
              description: "GUARD_SENTINEL: keep the existing suite",
              guard?: true
            )
          ],
          scope:
            Scope.new(
              paths: ["lib/widget.ex", "test/widget_test.exs"],
              write_paths: ["lib/widget.ex"]
            ),
          conventions: %{process_contract: false, extra_rules: []},
          metadata: %{script_pid: pid}
        )

      {:ok, loop} =
        Kazi.Loop.start_link(
          goal: goal,
          providers: %{tests: ScriptedProvider},
          harness: RecordingHarness,
          integrate: NoopIntegrate,
          deploy: NoopDeploy,
          workspace: "/fixture/ws",
          adapter_opts: [collector: self(), context_tier: unquote(tier)],
          reobserve_interval_ms: 5,
          flake_max_retries: 0,
          stuck_iterations: 0
        )

      assert {:ok, _} = Kazi.Loop.await(loop, 5_000)
      assert_received {:dispatched, first}
      assert_received {:dispatched, second}

      for prompt <- [first, second] do
        for required <- [
              "TASK_BRIEF_SENTINEL",
              "CODE_REQUIREMENT_SENTINEL",
              "GUARD_SENTINEL",
              "Repair the widget",
              "Preserve the public widget behavior.",
              "test/widget_test.exs",
              "Read paths:",
              "Write paths:",
              "mix"
            ] do
          assert prompt =~ required
        end

        refute prompt =~ "HIDDEN_REQUIREMENT_SENTINEL"
        refute prompt =~ "hidden-check-command"
      end

      assert task_of(first) == task_of(second)
      assert second =~ "fix failing predicates: code"
    end
  end

  test "quarantined definitions are excluded while real requirements remain" do
    goal =
      Goal.new("quarantine-contract",
        predicates: [
          Predicate.new(:flaky, :tests,
            description: "QUARANTINED_REQUIREMENT",
            config: %{cmd: "quarantined-command"}
          ),
          Predicate.new(:real, :tests, description: "REAL_REQUIREMENT")
        ]
      )

    rendered = Kazi.Harness.Prompt.task_contract(goal, MapSet.new([:flaky]))
    assert rendered =~ "REAL_REQUIREMENT"
    refute rendered =~ "QUARANTINED_REQUIREMENT"
    refute rendered =~ "quarantined-command"
    refute rendered =~ "flaky"
  end

  test "a long mandatory brief is not shortened to an orientation allowance" do
    brief = "BRIEF_START " <> String.duplicate("required detail ", 2_000) <> " BRIEF_END"

    goal =
      Goal.new("long-contract", predicates: [Predicate.new(:code, :tests, description: brief)])

    rendered = Kazi.Harness.Prompt.task_contract(goal)
    assert rendered =~ brief
    assert byte_size(rendered) > 16_000
  end

  test "contract rendering preserves empty definitions and redacts egress secrets" do
    goal =
      Goal.new("contract",
        predicates: [
          Predicate.new(:empty, :tests),
          Predicate.new(:secret, :tests,
            description: "Read password=fixture-secret before running."
          )
        ]
      )

    text = Kazi.Harness.Prompt.task_contract(goal)
    assert text =~ "empty"
    refute text =~ "fixture-secret"
  end

  defp task_of(prompt) do
    [head | _] = String.split(prompt, "\nevidence:", parts: 2)
    head
  end
end

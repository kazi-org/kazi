defmodule Kazi.Loop.ProcessContractPromptTest do
  @moduledoc """
  T44.4 (ADR-0055 decision 4b): the controller-owned PROCESS CONTRACT is appended
  to the dispatch prompt (after the T19.1 orientation prefix, before the work
  item) and is:

    * present by DEFAULT (process contract on);
    * BYTE-IDENTICAL across iterations of the same goal (the cacheable head);
    * carrying `extra_rules` verbatim;
    * ABSENT — and the prompt byte-identical to the pre-E44 body — when
      `process_contract = false`.

  Drives a real dispatch through `Kazi.Loop` with a recording harness capturing
  the exact prompt, no graph source (so the prompt is contract → work-item →
  evidence, isolating the contract), no network.
  """
  use ExUnit.Case, async: true

  alias Kazi.{Goal, Predicate}

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
            [last] -> {last, %{script | id => [last]}}
            [next | rest] -> {next, %{script | id => rest}}
          end
        end)

      Kazi.PredicateResult.new(status, %{output: "boom"})
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
    def execute(%Kazi.Action{kind: :integrate}, _context), do: {:ok, %{pr: 1}}
  end

  defmodule NoopDeploy do
    @behaviour Kazi.Action
    @impl true
    def execute(%Kazi.Action{kind: :deploy}, _context), do: {:ok, %{ref: "v1"}}
  end

  defp run_loop(script, conventions) do
    {:ok, script_pid} = ScriptedProvider.start_link(script)

    goal =
      Goal.new("process-contract-test",
        predicates: [Predicate.new(:code, :tests)],
        conventions: conventions,
        metadata: %{script_pid: script_pid}
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: ScriptedProvider},
        harness: RecordingHarness,
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        workspace: "/fixture/ws",
        adapter_opts: [collector: self()],
        reobserve_interval_ms: 5,
        flake_max_retries: 0,
        stuck_iterations: 0
      )

    {:ok, _result} = Kazi.Loop.await(loop, 5_000)
    :ok
  end

  @header "## Process contract (kazi-owned, stable across iterations)"

  test "the contract is present by default and identical across two iterations" do
    # fail, fail, pass ⇒ two dispatches (same failing set), then converge.
    :ok = run_loop(%{code: [:fail, :fail, :pass]}, Goal.default_conventions())

    assert_received {:dispatched, first}
    assert_received {:dispatched, second}

    assert first =~ @header
    assert second =~ @header

    # The contract section (header up to the work-item that follows it) is
    # BYTE-IDENTICAL across the two iterations — the cacheable head.
    assert contract_of(first) == contract_of(second)

    # Positioned BEFORE the work item.
    assert :binary.match(first, @header) |> elem(0) <
             :binary.match(first, "goal=process-contract-test") |> elem(0)
  end

  test "extra_rules appear verbatim in the dispatched prompt" do
    :ok =
      run_loop(%{code: [:fail, :pass]}, %{
        process_contract: true,
        extra_rules: ["Never push to main directly."]
      })

    assert_received {:dispatched, prompt}
    assert prompt =~ "- Never push to main directly."
  end

  test "process_contract = false yields a prompt byte-identical to the pre-E44 body" do
    :ok = run_loop(%{code: [:fail, :pass]}, Goal.default_conventions())
    assert_received {:dispatched, enabled}

    :ok = run_loop(%{code: [:fail, :pass]}, %{process_contract: false, extra_rules: []})
    assert_received {:dispatched, disabled}

    # Disabled carries NO contract...
    refute disabled =~ @header
    # ...and the disabled prompt is exactly the enabled prompt with the contract
    # block (and its trailing blank line) removed — i.e. disabling reverts
    # byte-for-byte, the regression pin.
    assert disabled == String.replace(enabled, contract_of(enabled) <> "\n\n", "", global: false)
    # And it begins right at the work item (the pre-E44 evidence-only body).
    assert String.starts_with?(disabled, "goal=process-contract-test")
  end

  # The contract block: from the header up to (but excluding) the blank line +
  # work-item line that follows it.
  defp contract_of(prompt) do
    {start, _} = :binary.match(prompt, @header)
    rest = binary_part(prompt, start, byte_size(prompt) - start)
    [contract | _] = String.split(rest, "\n\ngoal=", parts: 2)
    contract
  end
end

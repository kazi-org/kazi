defmodule Kazi.Harness.ClaudeAdapterBudgetTest do
  @moduledoc """
  End-to-end token accounting (T4.1, UC-009): the REAL `Kazi.Harness.ClaudeAdapter`
  driving a JSON-emitting stub binary, wired through a `Kazi.Loop` with a token
  budget, proving the loop's T1.4 budget guard CONSUMES the real token usage the
  adapter parsed from the `--output-format json` envelope.

  This is the integration counterpart to `Kazi.LoopBudgetTest` (which drives the
  token dimension via a hand-rolled harness double): here the tokens come from a
  genuine subprocess + JSON parse, so the whole seam — invoke → parse → accumulate
  → check ceiling → stop :over_budget — is exercised across the real process
  boundary. Hermetic: a stub shell script, no network, no real `claude`.
  """
  # Not async: the stub's token counts are driven via process-global OS env.
  use ExUnit.Case, async: false

  alias Kazi.{Action, Goal, Predicate, PredicateResult}
  alias Kazi.Harness.ClaudeAdapter

  @json_stub Path.expand("../../support/stub_claude_json.sh", __DIR__)

  # A predicate that never passes, so the ONLY terminator is the token budget:
  # the loop keeps dispatching the (real) adapter against the JSON stub, each run
  # adding its parsed token total until the ceiling trips.
  defmodule NeverConvergingProvider do
    @behaviour Kazi.PredicateProvider
    @impl true
    def evaluate(%Predicate{id: id}, _context),
      do: PredicateResult.fail(%{id: id, status: :fail})
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
    workspace =
      Path.join(System.tmp_dir!(), "kazi-adapter-budget-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  test "the loop's token budget consumes the adapter's parsed JSON token usage", %{
    workspace: workspace
  } do
    # Pin the stub's token total to a known small number so the ceiling is hit in
    # a predictable handful of dispatches: 30 + 20 = 50 tokens per run.
    System.put_env("STUB_INPUT_TOKENS", "30")
    System.put_env("STUB_OUTPUT_TOKENS", "20")
    System.put_env("STUB_CACHE_READ_TOKENS", "0")
    System.put_env("STUB_CACHE_CREATION_TOKENS", "0")

    on_exit(fn ->
      ~w(STUB_INPUT_TOKENS STUB_OUTPUT_TOKENS STUB_CACHE_READ_TOKENS STUB_CACHE_CREATION_TOKENS)
      |> Enum.each(&System.delete_env/1)
    end)

    goal =
      Goal.new("adapter-budget",
        predicates: [Predicate.new(:code, :tests)],
        budget: Kazi.Budget.new(max_tokens: 120)
      )

    {:ok, loop} =
      Kazi.Loop.start_link(
        goal: goal,
        providers: %{tests: NeverConvergingProvider},
        # The adapter runs the real subprocess in this workspace (so its `cd:`
        # and JSON parse are genuinely exercised).
        workspace: workspace,
        # The REAL adapter, driving the JSON stub via the :command opt.
        harness: ClaudeAdapter,
        adapter_opts: [command: @json_stub],
        integrate: NoopIntegrate,
        deploy: NoopDeploy,
        reobserve_interval_ms: 1,
        # Isolate the BUDGET dimension: a constant failing set would otherwise
        # trip the stuck detector first.
        stuck_iterations: 0
      )

    assert {:ok, result} = Kazi.Loop.await(loop, 10_000)

    # The token budget — fed by the adapter's parsed JSON usage — stopped the loop.
    assert result.outcome == :over_budget
    assert result.reason == :token_budget

    snap = Kazi.Loop.snapshot(loop)
    assert snap.budget_reason == :token_budget
    # Accumulated real token usage crossed the 120-token ceiling (50 per run).
    assert snap.tokens_used >= 120

    # Sanity: the adapter genuinely ran the subprocess (workspace marker present).
    assert File.exists?(Path.join(workspace, "stub_edit.txt"))
  end
end

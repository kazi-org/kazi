defmodule Kazi.Loop.RetrievalOptInTest do
  use ExUnit.Case, async: true

  # T4.9c (verifies UC-022, UC-006): per-goal retrieval opt-in, OFF by default. These
  # tests drive the real `Kazi.Loop` gen_statem with hermetic doubles (no network, no
  # real harness, a fixed `StaticRetriever`) and assert on the prompts the harness
  # double receives:
  #
  #   * OFF by default — with NO `:retriever` in adapter_opts the dispatch prompt is
  #     byte-identical to the pre-retrieval path (no retrieval section);
  #   * ENABLED — with a `:retriever` threaded into adapter_opts the dispatch prompt
  #     carries the retrieved snippets in the dedicated, clearly-delimited section,
  #     AFTER the live failing-evidence (augmenting, never replacing it).

  alias Kazi.{Goal, Predicate, PredicateResult}
  alias Kazi.Retrieval.StaticRetriever

  @retrieval_heading "## Relevant prior context (retrieved)"

  # A provider scripted per-id across observations (same shape as the digest test):
  # pops the next status, holding the last forever — so the loop dispatches.
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

  # Harness double: records each prompt it is handed to the collector.
  defmodule RecordingHarness do
    @behaviour Kazi.HarnessAdapter

    @impl true
    def run(prompt, workspace, opts) do
      send(Keyword.fetch!(opts, :collector), {:dispatched, prompt, workspace})
      {:ok, %{output: "{}", cost: %{tokens: 1}}}
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

  defp start_loop(script, collector, adapter_opts) do
    {:ok, script_pid} = ScriptedProvider.start_link(script)

    goal =
      Goal.new("retr-test",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{script_pid: script_pid}
      )

    Kazi.Loop.start_link(
      goal: goal,
      providers: %{tests: ScriptedProvider},
      harness: RecordingHarness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      adapter_opts: Keyword.put(adapter_opts, :collector, collector),
      reobserve_interval_ms: 5,
      flake_max_retries: 0,
      stuck_iterations: 0
    )
  end

  defp collect_prompts(n) do
    for _ <- 1..n do
      assert_receive {:dispatched, prompt, _ws}, 1_000
      prompt
    end
  end

  test "OFF by default: no :retriever leaves the dispatch prompt unchanged" do
    {:ok, _loop} = start_loop(%{code: [:fail, :pass]}, self(), [])

    [prompt] = collect_prompts(1)

    # Byte-for-byte the evidence prompt: a goal line + an evidence line, no
    # retrieval section appended.
    assert prompt =~ "goal=retr-test fix failing predicates: code"
    refute prompt =~ @retrieval_heading
    # The whole prompt is exactly two lines (goal + evidence) — nothing appended.
    assert length(String.split(prompt, "\n")) == 2
  end

  test "ENABLED: a goal-declared retriever injects snippets into the dispatch prompt" do
    retriever =
      StaticRetriever.new(
        snippets: [
          {"def build(x), do: x + 1", source: "lib/a.ex:42"},
          "a plain prior-context snippet"
        ]
      )

    {:ok, _loop} = start_loop(%{code: [:fail, :pass]}, self(), retriever: retriever)

    [prompt] = collect_prompts(1)

    # The live failing-evidence is still present (retrieval AUGMENTS, never replaces).
    assert prompt =~ "goal=retr-test fix failing predicates: code"

    # The retrieved snippets render in the dedicated, clearly-delimited section.
    assert prompt =~ @retrieval_heading
    assert prompt =~ "def build(x), do: x + 1"
    assert prompt =~ "lib/a.ex:42"
    assert prompt =~ "a plain prior-context snippet"

    # The section sits AFTER the failing-evidence body.
    {evidence_at, _} = :binary.match(prompt, "fix failing predicates")
    {retr_at, _} = :binary.match(prompt, @retrieval_heading)
    assert evidence_at < retr_at
  end

  test "ENABLED but the retriever returns []: nothing is appended (byte-identical to off)" do
    empty = StaticRetriever.new(snippets: [])

    {:ok, _loop} = start_loop(%{code: [:fail, :pass]}, self(), retriever: empty)

    [prompt] = collect_prompts(1)

    refute prompt =~ @retrieval_heading
    assert length(String.split(prompt, "\n")) == 2
  end
end

defmodule Kazi.Loop.WorkingSetDigestTest do
  use ExUnit.Case, async: true

  # T4.7 (verifies UC-022): the loop threads a BOUNDED working-set digest from one
  # iteration's harness result into the NEXT iteration's prompt — MAP MEMORY, NOT
  # conversation memory. These tests drive the real `Kazi.Loop` gen_statem with
  # hermetic doubles (no network, no real harness) and assert on the prompts the
  # harness double receives across consecutive dispatches:
  #
  #   * the next prompt carries a COMPACT files-touched note derived from the prior
  #     iteration's `:touched` set;
  #   * NO transcript / conversation text from the prior iteration is carried (the
  #     ADR-0008 anti-anchoring guarantee, enforced structurally);
  #   * the digest is BOUNDED (the file cap is respected in the carried prompt);
  #   * the FIRST iteration (no prior touched set) leaves the prompt unchanged.

  alias Kazi.{Goal, Predicate, PredicateResult}

  # A provider scripted per-id across observations: pops the next status, holding
  # the last forever. Lets us script "code fails twice, then passes" so the loop
  # dispatches more than once (so there IS a next prompt to inspect).
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

  # Harness double: records each prompt it is handed to the collector, and reports
  # BOTH a touched working set (map memory the loop should carry forward) AND a
  # transcript-shaped `:result`/`:output` (conversation memory the loop must NOT
  # carry). The reported touched set is read from adapter_opts so a test can make
  # it large (to exercise the bound). It carries a token estimate so the loop's
  # budget accounting is exercised unchanged.
  defmodule TouchReportingHarness do
    @behaviour Kazi.HarnessAdapter

    @secret_transcript "I tried approach ALPHA, it failed because of a flaky mock, " <>
                         "then I rewrote the lexer using approach BETA"

    def secret_transcript, do: @secret_transcript

    @impl true
    def run(prompt, workspace, opts) do
      send(Keyword.fetch!(opts, :collector), {:dispatched, prompt, workspace})
      touched = Keyword.get(opts, :touched, ["lib/parser.ex", "lib/lexer.ex"])

      {:ok,
       %{
         output: ~s({"result":"#{@secret_transcript}"}),
         result: @secret_transcript,
         touched: touched,
         cost: %{tokens: 1}
       }}
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
      Goal.new("digest-test",
        predicates: [Predicate.new(:code, :tests)],
        metadata: %{script_pid: script_pid, collector: collector}
      )

    Kazi.Loop.start_link(
      goal: goal,
      providers: %{tests: ScriptedProvider},
      harness: TouchReportingHarness,
      integrate: NoopIntegrate,
      deploy: NoopDeploy,
      adapter_opts: Keyword.put(adapter_opts, :collector, collector),
      reobserve_interval_ms: 5,
      flake_max_retries: 0,
      stuck_iterations: 0
    )
  end

  # Collect the first `n` dispatched prompts in order.
  defp collect_prompts(n) do
    for _ <- 1..n do
      assert_receive {:dispatched, prompt, _ws}, 1_000
      prompt
    end
  end

  test "the next prompt carries a compact files-touched note from the prior iteration" do
    # Code fails on observations 0 and 1 (two dispatches), then passes.
    {:ok, _loop} = start_loop(%{code: [:fail, :fail, :pass]}, self(), [])

    [first_prompt, second_prompt] = collect_prompts(2)

    # First iteration: no prior touched set, so the prompt is the plain evidence
    # string — no working-set note.
    refute first_prompt =~ "Working set"
    refute first_prompt =~ "lib/parser.ex"

    # Second iteration: carries the bounded files-touched note distilled from the
    # FIRST iteration's reported `:touched` set.
    assert second_prompt =~ "Working set"
    assert second_prompt =~ "map memory"
    assert second_prompt =~ "lib/parser.ex"
    assert second_prompt =~ "lib/lexer.ex"
    # And it still carries the live failing evidence (the digest is PREPENDED, not
    # a replacement).
    assert second_prompt =~ "fix failing predicates"
  end

  test "NO transcript / conversation memory is carried into the next prompt" do
    {:ok, _loop} = start_loop(%{code: [:fail, :fail, :pass]}, self(), [])

    [_first, second_prompt] = collect_prompts(2)

    transcript = TouchReportingHarness.secret_transcript()

    # The harness reported a fat transcript in :result/:output, but NONE of it may
    # appear in the next prompt — only the touched file paths (map memory).
    refute second_prompt =~ transcript
    refute second_prompt =~ "approach ALPHA"
    refute second_prompt =~ "approach BETA"
    refute second_prompt =~ "failed because"
  end

  test "the carried digest is bounded: the file cap is respected in the next prompt" do
    # The harness reports a large touched set; the loop's digest caps it (default
    # 20) and folds the rest behind a (+N more) count. The next prompt must carry
    # the bound, not all 50 paths.
    big = for i <- 1..50, do: "lib/mod_#{i}.ex"
    {:ok, _loop} = start_loop(%{code: [:fail, :fail, :pass]}, self(), touched: big)

    [_first, second_prompt] = collect_prompts(2)

    # Count the bulleted file lines carried in the note. The default cap is 20.
    file_bullets =
      second_prompt
      |> String.split("\n")
      |> Enum.filter(&String.match?(&1, ~r/^- lib\/mod_\d+\.ex$/))

    assert length(file_bullets) <= 20
    assert second_prompt =~ "more)"
    # Not every path leaked through.
    refute second_prompt =~ "lib/mod_50.ex"
  end

  test "first iteration (no prior touched set) leaves the prompt unchanged" do
    {:ok, _loop} = start_loop(%{code: [:fail, :pass]}, self(), [])

    [first_prompt] = collect_prompts(1)

    # Byte-for-byte the evidence prompt: a goal line + an evidence line, nothing
    # prepended.
    assert first_prompt =~ "goal=digest-test fix failing predicates: code"
    refute first_prompt =~ "Working set"
    # The whole prompt is exactly two lines (goal + evidence) — no digest section.
    assert length(String.split(first_prompt, "\n")) == 2
  end
end

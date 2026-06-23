defmodule Kazi.Harness.PromptTest do
  # T8.3 (UC-027, ADR-0016): direct coverage of the harness-neutral prompt
  # construction extracted from `Kazi.Harness.ClaudeAdapter` into the vendor-neutral
  # `Kazi.Harness.Prompt`. The Claude adapter still exercises these via delegation
  # (see claude_adapter_test.exs); here we test the neutral module on its own.
  use ExUnit.Case, async: true

  doctest Kazi.Harness.Prompt

  alias Kazi.Context
  alias Kazi.Context.StaticGraphSource
  alias Kazi.Harness.Prompt
  alias Kazi.PredicateResult

  describe "build_prompt/2 (pure prompt construction)" do
    test "seeds the work item plus failing-predicate evidence" do
      failing = [
        {:unit, PredicateResult.fail(%{output: "1 test, 1 failure", exit: 1})},
        {:live, PredicateResult.fail(%{http_status: 500, url: "https://x/health"})}
      ]

      prompt = Prompt.build_prompt("Make the suite green", failing)

      assert prompt =~ "Make the suite green"
      assert prompt =~ "Failing predicate: unit"
      assert prompt =~ "Failing predicate: live"
      assert prompt =~ "1 test, 1 failure"
      assert prompt =~ "http_status: 500"
      # Guards against the agent "passing" a predicate by deleting the check.
      assert prompt =~ "not the checks themselves"
    end

    test "handles a failing predicate with no evidence" do
      prompt = Prompt.build_prompt("fix it", [{:unit, PredicateResult.fail()}])
      assert prompt =~ "(no evidence captured)"
    end

    test "renders just the work item when nothing is failing" do
      prompt = Prompt.build_prompt("nothing failing", [])
      assert prompt =~ "nothing failing"
      refute prompt =~ "Failing predicate"
    end
  end

  describe "build_prompt/3 (stable orientation prefix, T4.3)" do
    @workspace "/fixture/ws"

    defp orientation_source do
      StaticGraphSource.new(
        origin: :graph,
        files: ["lib/target.ex", "lib/helper.ex"],
        symbols: [{"build/1", "lib/target.ex", [callers: ["caller/0"]]}],
        test_sources: [{"test/target_test.exs", [source: "assert Target.build(1)"]}]
      )
    end

    defp failing_unit do
      [{:unit, PredicateResult.fail(%{output: "boom in lib/target.ex:42"})}]
    end

    test "with no context opt, build_prompt/3 is byte-identical to build_prompt/2" do
      failing = failing_unit()

      assert Prompt.build_prompt("fix it", failing, []) ==
               Prompt.build_prompt("fix it", failing)
    end

    test "prepends the rendered orientation pack as the prompt head (:workspace)" do
      prompt =
        Prompt.build_prompt("fix it", failing_unit(),
          workspace: @workspace,
          graph_source: orientation_source()
        )

      assert prompt =~ "# Orientation"
      assert prompt =~ "lib/target.ex"
      assert prompt =~ "build/1"

      {orient, _} = :binary.match(prompt, "# Orientation")
      {evidence, _} = :binary.match(prompt, "The following predicates are currently failing.")
      assert orient < evidence
    end

    test "accepts a pre-built :context_pack, rendering it verbatim as the prefix" do
      pack =
        Context.orientation_pack(failing_unit(), @workspace, graph_source: orientation_source())

      prompt = Prompt.build_prompt("fix it", failing_unit(), context_pack: pack)
      assert prompt =~ Context.render(pack)
    end

    test "the orientation prefix is byte-identical across iterations for the same inputs" do
      opts = [workspace: @workspace, graph_source: orientation_source()]

      first = Prompt.build_prompt("fix it", failing_unit(), opts)
      second = Prompt.build_prompt("fix it", failing_unit(), opts)

      assert first == second
    end
  end

  describe "render_retrieval_section/1 (T4.9a, ADR-0012)" do
    alias Kazi.Retrieval.Snippet

    test "renders snippets under a fixed, greppable heading with source attribution" do
      section =
        Prompt.render_retrieval_section([
          %Snippet{text: "def build(x), do: x + 1", source: "lib/target.ex:42"},
          %Snippet{text: "a sourceless hint", source: nil}
        ])

      assert section =~ "## Relevant prior context (retrieved)"
      assert section =~ "lib/target.ex:42"
      assert section =~ "def build(x), do: x + 1"
      assert section =~ "a sourceless hint"
    end
  end

  describe "truncate_evidence/2 (pure, T4.8, UC-009/UC-022)" do
    test "returns input verbatim when within the byte budget" do
      assert Prompt.truncate_evidence("short evidence", max_bytes: 1_024) == "short evidence"
    end

    test "keeps a head and a tail around the marker (both signals survive)" do
      body = String.duplicate("-", 5_000)
      evidence = "FAILURE_HEAD" <> body <> "RESOLUTION_TAIL"

      out = Prompt.truncate_evidence(evidence, max_bytes: 200)

      assert out =~ "FAILURE_HEAD"
      assert out =~ "RESOLUTION_TAIL"
      assert out =~ "…truncated…"
      assert byte_size(out) <= 200
    end

    test "defaults to the module's evidence budget when no max_bytes given" do
      big = String.duplicate("y", 100_000)
      out = Prompt.truncate_evidence(big)

      assert byte_size(out) < byte_size(big)
      assert byte_size(out) <= 8_192
      assert out =~ "…truncated…"
    end

    test "never splits a multi-byte UTF-8 codepoint (valid strings out)" do
      evidence = String.duplicate("🔥", 1_000)
      out = Prompt.truncate_evidence(evidence, max_bytes: 101)

      assert byte_size(out) <= 101
      assert String.valid?(out)
    end
  end
end

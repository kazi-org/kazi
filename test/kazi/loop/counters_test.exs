defmodule Kazi.Loop.CountersTest do
  @moduledoc """
  T34.3 (ADR-0046 §2): the pure per-iteration `context` + `tools` counter logic.

    * `context/5` reports the orientation/retrieval cache state (disabled when a
      section was not sent, hit when byte-identical to the prior dispatch, miss
      otherwise) and the per-section token estimates — always fully populated, so
      a `0` is a measured zero, never "unknown";
    * `tools/1` classifies a harness result's tool-use stream into
      tool_calls/file_reads/search_calls/graph_calls when the harness exposed one,
      and returns the EMPTY map when it did not (absent ≠ zero).
  """
  use ExUnit.Case, async: true

  alias Kazi.Loop.Counters

  describe "context/5 — cache state" do
    test "a section that was not sent is disabled" do
      ctx = Counters.context(nil, "evidence: boom", nil, nil, nil)
      assert ctx.orientation_cache == "disabled"
      assert ctx.retrieval_cache == "disabled"
    end

    test "a fresh prefix (no prior, or changed) is a miss" do
      # First dispatch: a prefix exists but there is no prior to match → miss.
      first = Counters.context("# Orientation\nlib/widget.ex", "ev", nil, nil, nil)
      assert first.orientation_cache == "miss"

      # A CHANGED prefix vs the prior dispatch → miss.
      changed =
        Counters.context(
          "# Orientation\nlib/other.ex",
          "ev",
          nil,
          "# Orientation\nlib/widget.ex",
          nil
        )

      assert changed.orientation_cache == "miss"
    end

    test "a byte-identical prefix vs the prior dispatch is a hit" do
      prefix = "# Orientation\nlib/widget.ex"
      ctx = Counters.context(prefix, "ev", nil, prefix, nil)
      assert ctx.orientation_cache == "hit"
    end

    test "retrieval cache is tracked independently of orientation" do
      r = "# Retrieval\nsnippet"
      ctx = Counters.context(nil, "ev", r, nil, r)
      assert ctx.orientation_cache == "disabled"
      assert ctx.retrieval_cache == "hit"
    end
  end

  describe "context/5 — token estimates" do
    test "estimates each section as ceil(chars / 4); an absent section is 0" do
      ctx = Counters.context("abcdefgh", "evidence!", nil, nil, nil)
      # 8 chars → 2 tokens; 9 chars → 3 tokens; absent retrieval → 0.
      assert ctx.orientation_tokens == 2
      assert ctx.evidence_tokens == 3
      assert ctx.retrieval_tokens == 0
    end

    test "empty_context/0 is all-disabled / all-zero / no-tier (the no-dispatch baseline)" do
      assert Counters.empty_context() == %{
               orientation_cache: "disabled",
               retrieval_cache: "disabled",
               orientation_tokens: 0,
               evidence_tokens: 0,
               retrieval_tokens: 0,
               tier: nil
             }
    end
  end

  describe "context/6 — active context tier (T36.3, ADR-0047 §3)" do
    test "the tier defaults to nil so the pure section-counting contract is unchanged" do
      ctx = Counters.context("# Orientation", "ev", nil, nil, nil)
      assert ctx.tier == nil
    end

    test "records the active tier passed by the loop" do
      ctx = Counters.context("# Orientation", "ev", nil, nil, nil, 2)
      assert ctx.tier == 2
      # The section counters are unaffected by the tier.
      assert ctx.orientation_cache == "miss"
      assert ctx.evidence_tokens > 0
    end

    test "tier 0 is recorded as the integer 0 (not treated as absent)" do
      ctx = Counters.context(nil, "ev", nil, nil, nil, 0)
      assert ctx.tier == 0
    end
  end

  describe "estimate_tokens/1" do
    test "nil and empty string are 0; otherwise ceil(chars / 4)" do
      assert Counters.estimate_tokens(nil) == 0
      assert Counters.estimate_tokens("") == 0
      assert Counters.estimate_tokens("a") == 1
      assert Counters.estimate_tokens("abcd") == 1
      assert Counters.estimate_tokens("abcde") == 2
    end
  end

  describe "tools/1 — present signal" do
    test "classifies a string tool-use stream into the four buckets" do
      result =
        {:ok,
         %{tool_uses: ["Read", "Read", "Grep", "Bash", "mcp__code-review-graph__query_graph"]}}

      assert Counters.tools(result) == %{
               tool_calls: 5,
               file_reads: 2,
               search_calls: 1,
               graph_calls: 1
             }
    end

    test "accepts tool-use BLOCK maps carrying a name" do
      result = %{
        tool_uses: [
          %{"type" => "tool_use", "name" => "Read"},
          %{"name" => "Glob"},
          %{name: "semantic_search_nodes"}
        ]
      }

      assert Counters.tools(result) == %{
               tool_calls: 3,
               file_reads: 1,
               search_calls: 1,
               graph_calls: 1
             }
    end

    test "an empty (but present) tool-use stream reports zeros, not absence" do
      assert Counters.tools(%{tool_uses: []}) == %{
               tool_calls: 0,
               file_reads: 0,
               search_calls: 0,
               graph_calls: 0
             }
    end
  end

  describe "tools/1 — absent signal (honest-unknown)" do
    test "a result with no tool-use stream yields the EMPTY map (absent ≠ zero)" do
      assert Counters.tools({:ok, %{output: "ok", tokens: 10}}) == %{}
      assert Counters.tools(%{output: "ok"}) == %{}
    end

    test "an error result yields the empty map" do
      assert Counters.tools({:error, :boom}) == %{}
    end
  end
end

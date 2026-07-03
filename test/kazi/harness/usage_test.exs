defmodule Kazi.Harness.UsageTest do
  # T34.2 (UC-033, ADR-0046): the shared raw-usage -> economy-envelope mapper and
  # its per-parse fidelity marker, plus the Claude profile's use of it. The Codex
  # profile's mapping is covered in codex_profile_test.exs; the recorded golden
  # transcripts pin both in conformance_test.exs.
  #
  # async: true — pure functions + literal data, no OS env or disk.
  use ExUnit.Case, async: true

  alias Kazi.Harness.Profiles.Claude
  alias Kazi.Harness.Usage

  # The Anthropic field -> envelope field map, the same one the Claude profile
  # uses (input/output verbatim; cache_creation -> cache_write, cache_read ->
  # cached_input). Declared here so the mapper cases read against a real mapping.
  @anthropic_mapping [
    {"input_tokens", :input_tokens},
    {"output_tokens", :output_tokens},
    {"cache_creation_input_tokens", :cache_write_tokens},
    {"cache_read_input_tokens", :cached_input_tokens}
  ]

  describe "Usage.map/2 — raw -> envelope + fidelity" do
    test "all mapped fields present -> :full, each carried to its envelope field" do
      raw = %{
        "input_tokens" => 100,
        "output_tokens" => 250,
        "cache_creation_input_tokens" => 7,
        "cache_read_input_tokens" => 5000
      }

      assert Usage.map(raw, @anthropic_mapping) ==
               {%{
                  input_tokens: 100,
                  output_tokens: 250,
                  cache_write_tokens: 7,
                  cached_input_tokens: 5000
                }, :full}
    end

    test "some but not all fields present -> :partial; unreported fields OMITTED" do
      # Only fresh input + output; the two cache classes are unreported and must
      # NOT appear as zeros (absent ≠ zero).
      raw = %{"input_tokens" => 100, "output_tokens" => 250}

      assert Usage.map(raw, @anthropic_mapping) ==
               {%{input_tokens: 100, output_tokens: 250}, :partial}
    end

    test "a reported 0 IS a report (kept), distinct from an absent field" do
      raw = %{"input_tokens" => 0, "output_tokens" => 250}

      assert Usage.map(raw, @anthropic_mapping) ==
               {%{input_tokens: 0, output_tokens: 250}, :partial}
    end

    test "no mapped fields present -> :none with an empty envelope" do
      assert Usage.map(%{}, @anthropic_mapping) == {%{}, :none}
      # A non-integer / negative value is not a usable report.
      assert Usage.map(%{"input_tokens" => "lots"}, @anthropic_mapping) == {%{}, :none}
      assert Usage.map(%{"input_tokens" => -5}, @anthropic_mapping) == {%{}, :none}
    end
  end

  describe "Claude.parse/1 — Anthropic usage onto the envelope (T34.2)" do
    test "maps the four Anthropic fields, retains the raw object, marks :full" do
      envelope =
        ~s({"result":"done","usage":{"input_tokens":100,"output_tokens":250,) <>
          ~s("cache_creation_input_tokens":0,"cache_read_input_tokens":5000}})

      parsed = Claude.parse(envelope)

      # Anthropic -> envelope: input/output verbatim, cache_creation ->
      # cache_write, cache_read -> cached_input.
      assert parsed.usage == %{
               input_tokens: 100,
               output_tokens: 250,
               cache_write_tokens: 0,
               cached_input_tokens: 5000
             }

      assert parsed.usage_raw == %{
               "input_tokens" => 100,
               "output_tokens" => 250,
               "cache_creation_input_tokens" => 0,
               "cache_read_input_tokens" => 5000
             }

      assert parsed.usage_fidelity == :full
      # The back-compat rollup is untouched: 100 + 250 + 0 + 5000.
      assert parsed.tokens == 5350
    end

    test "a usage object with only some fields maps to :partial (unreported omitted)" do
      envelope = ~s({"result":"done","usage":{"input_tokens":100,"output_tokens":250}})

      parsed = Claude.parse(envelope)

      assert parsed.usage == %{input_tokens: 100, output_tokens: 250}
      refute Map.has_key?(parsed.usage, :cache_write_tokens)
      refute Map.has_key?(parsed.usage, :cached_input_tokens)
      assert parsed.usage_fidelity == :partial
    end

    test "a valid envelope with NO usage object reports :none (never zeros)" do
      parsed = Claude.parse(~s({"result":"done"}))

      assert parsed.result == "done"
      assert parsed.usage_fidelity == :none
      refute Map.has_key?(parsed, :usage)
      refute Map.has_key?(parsed, :usage_raw)
      # No fabricated rollup either.
      refute Map.has_key?(parsed, :tokens)
    end

    test "non-JSON output stays %{} — no harness turn to annotate" do
      assert Claude.parse("not json at all") == %{}
    end
  end

  describe "Claude.parse/1 — tool-use names (T34.3, ADR-0046 §2)" do
    test "the default --output-format json envelope carries no per-tool data → :tool_uses absent" do
      parsed = Claude.parse(~s({"result":"done","num_turns":3}))
      refute Map.has_key?(parsed, :tool_uses)
    end

    test "a richer envelope with messages[].content[] tool_use blocks surfaces the names in order" do
      envelope =
        ~s({"result":"done","messages":[) <>
          ~s({"role":"assistant","content":[) <>
          ~s({"type":"text","text":"thinking"},) <>
          ~s({"type":"tool_use","name":"Read"},) <>
          ~s({"type":"tool_use","name":"Grep"}]},) <>
          ~s({"role":"assistant","content":[) <>
          ~s({"type":"tool_use","name":"Read"}]}]})

      parsed = Claude.parse(envelope)
      assert parsed.tool_uses == ["Read", "Grep", "Read"]
    end

    test "messages without tool_use content yield no :tool_uses key" do
      envelope =
        ~s({"result":"done","messages":[{"role":"assistant","content":[) <>
          ~s({"type":"text","text":"just text"}]}]})

      refute Map.has_key?(Claude.parse(envelope), :tool_uses)
    end
  end

  describe "Claude.parse/1 — permission_denials (issue #769)" do
    test "an envelope with no permission_denials omits the key" do
      parsed = Claude.parse(~s({"result":"done","num_turns":3}))
      refute Map.has_key?(parsed, :permission_denials)
    end

    test "an empty permission_denials array omits the key" do
      parsed = Claude.parse(~s({"result":"done","permission_denials":[]}))
      refute Map.has_key?(parsed, :permission_denials)
    end

    test "a denied tool call surfaces tool_name/tool_input/tool_use_id" do
      envelope =
        ~s({"result":"I need permission to write the file","permission_denials":[) <>
          ~s({"tool_name":"Write","tool_use_id":"toolu_01abc",) <>
          ~s("tool_input":{"file_path":"/tmp/kazi-repro/PROOF.txt","content":"converged"}}]})

      parsed = Claude.parse(envelope)

      assert parsed.permission_denials == [
               %{
                 tool_name: "Write",
                 tool_use_id: "toolu_01abc",
                 tool_input: %{
                   "file_path" => "/tmp/kazi-repro/PROOF.txt",
                   "content" => "converged"
                 }
               }
             ]
    end

    test "multiple denials are carried in order, each independently normalized" do
      envelope =
        ~s({"result":"denied","permission_denials":[) <>
          ~s({"tool_name":"Write"},{"tool_name":"Bash","tool_input":{"command":"ls"}}]})

      parsed = Claude.parse(envelope)

      assert parsed.permission_denials == [
               %{tool_name: "Write"},
               %{tool_name: "Bash", tool_input: %{"command" => "ls"}}
             ]
    end

    test "a malformed denial (no tool_name) is filtered out rather than crashing" do
      envelope =
        ~s({"result":"denied","permission_denials":[{"tool_input":{}},{"tool_name":"Edit"}]})

      parsed = Claude.parse(envelope)
      assert parsed.permission_denials == [%{tool_name: "Edit"}]
    end
  end
end

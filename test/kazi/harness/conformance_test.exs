defmodule Kazi.Harness.ConformanceTest do
  # T14.1 (ADR-0022): the uniform profile-conformance harness + the
  # golden-transcript pattern. This drives the EXISTING built-in profiles
  # (`:claude`, `:opencode`) through `Kazi.Harness.Conformance` against recorded
  # sample transcripts under `test/fixtures/harness/`, proving the helper itself
  # works end to end. Every NEW profile (Codex/Antigravity/claw in later tasks)
  # adds a case here by the same call shape — that is the point of the helper.
  #
  # Unlike the stub-binary seam (ProfileRegistryTest, which exercises the live
  # System.cmd boundary), this is purely about `build_args` (argv) and `parse`
  # (against frozen golden bytes the vendor really emits): no subprocess, fully
  # hermetic and deterministic. async: true — nothing here touches OS env or disk
  # writes; it only reads checked-in fixtures and calls pure profile functions.
  use ExUnit.Case, async: true

  import Kazi.Harness.Conformance

  alias Kazi.Harness.Conformance

  describe ":claude golden-transcript conformance" do
    test "argv + JSON-envelope parse against the recorded transcript" do
      parsed =
        assert_profile_conformance(:claude,
          prompt: "Make the suite green",
          opts: [],
          expected_argv: ["-p", "Make the suite green", "--output-format", "json"],
          transcript: "harness/claude_envelope.json",
          expected_parse: %{
            result: "Made the failing unit test pass.",
            # input 100 + output 250 + cache_read 5000 + cache_creation 0.
            tokens: 5350,
            cost: %{tokens: 5350},
            cost_usd: 0.0123,
            touched: ["lib/app/widget.ex", "test/app/widget_test.exs"]
          }
        )

      # The helper returns the parsed map for any extra bespoke assertions.
      assert parsed.tokens == 100 + 250 + 5000 + 0
    end

    test "argv renders the claw-code hygiene flags when their opts are supplied" do
      assert_profile_conformance(:claude,
        prompt: "Make the suite green",
        opts: [max_budget_usd: 1.25, allowed_tools: ["Read", "Edit"], permission_mode: :plan],
        expected_argv: [
          "-p",
          "Make the suite green",
          "--output-format",
          "json",
          "--max-budget-usd",
          "1.25",
          "--allowed-tools",
          "Read",
          "Edit",
          "--permission-mode",
          "plan"
        ],
        transcript: "harness/claude_envelope.json",
        expected_parse: %{
          result: "Made the failing unit test pass.",
          tokens: 5350,
          cost: %{tokens: 5350},
          cost_usd: 0.0123,
          touched: ["lib/app/widget.ex", "test/app/widget_test.exs"]
        }
      )
    end
  end

  describe ":opencode golden-transcript conformance" do
    test "argv + NDJSON event-stream parse against the recorded transcript" do
      assert_profile_conformance(:opencode,
        prompt: "fix the failing test",
        opts: [model: "dgx/qwen3.6"],
        expected_argv: [
          "run",
          "fix the failing test",
          "--format",
          "json",
          "--model",
          "dgx/qwen3.6"
        ],
        transcript: "harness/opencode_run.jsonl",
        expected_parse: %{
          result: "Made the failing unit test pass.",
          # input 120 + output 340 + reasoning 40 + cache.read 900 + cache.write 0.
          tokens: 1400,
          cost: %{tokens: 1400},
          cost_usd: 0.0042
        }
      )
    end

    test "argv without a model omits the --model flag (same recorded parse)" do
      assert_profile_conformance(:opencode,
        prompt: "fix the failing test",
        opts: [],
        expected_argv: ["run", "fix the failing test", "--format", "json"],
        transcript: "harness/opencode_run.jsonl",
        expected_parse: %{
          result: "Made the failing unit test pass.",
          tokens: 1400,
          cost: %{tokens: 1400},
          cost_usd: 0.0042
        }
      )
    end
  end

  describe "helper mechanics (the contract future profiles rely on)" do
    test "expected_parse is asserted as a strict subset: a missing field fails" do
      assert_raise ExUnit.AssertionError, ~r/omitted expected field/, fn ->
        assert_profile_conformance(:claude,
          prompt: "x",
          expected_argv: ["-p", "x", "--output-format", "json"],
          transcript: ~s({"result":"only text"}),
          inline_transcript: true,
          # The recording reports no usage, so :tokens must NOT be claimed present.
          expected_parse: %{result: "only text", tokens: 999}
        )
      end
    end

    test "an UNEXPECTED structured field (not vetted by the case) fails" do
      assert_raise ExUnit.AssertionError, ~r/unexpected structured fields/, fn ->
        assert_profile_conformance(:claude,
          prompt: "x",
          expected_argv: ["-p", "x", "--output-format", "json"],
          transcript: "harness/claude_envelope.json",
          # Under-declaring: the real transcript also yields tokens/cost/touched.
          expected_parse: %{result: "Made the failing unit test pass."}
        )
      end
    end

    test "an argv mismatch fails with a clear message" do
      assert_raise ExUnit.AssertionError, ~r/argv mismatch/, fn ->
        assert_profile_conformance(:opencode,
          prompt: "x",
          expected_argv: ["run", "x"],
          transcript: ~s({}),
          inline_transcript: true,
          expected_parse: %{}
        )
      end
    end

    test "a missing fixture flunks loudly instead of silently passing" do
      assert_raise ExUnit.AssertionError, ~r/golden transcript fixture not found/, fn ->
        Conformance.read_transcript("harness/does_not_exist.jsonl")
      end
    end

    test "read_transcript/1 exposes the raw recorded bytes for bespoke slices" do
      bytes = Conformance.read_transcript("harness/opencode_run.jsonl")
      assert is_binary(bytes)
      assert String.contains?(bytes, "Made the failing unit test pass.")
    end
  end
end

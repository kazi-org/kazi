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

  alias Kazi.Harness.{Conformance, Profile, Registry}

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

    # T19.6 (ADR-0033): in-family Claude tiering. A cheap Claude model selected via
    # `--model <m>` is appended to the argv; the same recorded envelope parses, so
    # only the argv differs.
    test "argv appends --model when a cheap in-family model is given (T19.6)" do
      assert_profile_conformance(:claude,
        prompt: "Make the suite green",
        opts: [model: "claude-haiku-4-5"],
        expected_argv: [
          "-p",
          "Make the suite green",
          "--output-format",
          "json",
          "--model",
          "claude-haiku-4-5"
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

    # Back-compat: with NO model the argv is byte-for-byte the pre-T19.6 shape (no
    # `--model` token); an empty-string model is likewise treated as no model.
    test "argv WITHOUT a model is byte-identical to today (omits --model, T19.6)" do
      profile = Registry.fetch!(:claude)
      base = ["-p", "Make the suite green", "--output-format", "json"]

      assert Profile.build_args(profile, "Make the suite green", []) == base
      assert Profile.build_args(profile, "Make the suite green", model: "") == base
      refute "--model" in Profile.build_args(profile, "Make the suite green", [])
    end

    # :model is declared in supported_opts so the profile's advertised surface is
    # honest (ADR-0022 conformance), even though Kazi.Harness always keeps :model.
    test "the :claude profile declares :model in supported_opts (T19.6)" do
      profile = Registry.fetch!(:claude)
      assert :model in profile.supported_opts
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

  describe ":codex golden-transcript conformance (T14.2, ADR-0022)" do
    test "argv + JSONL event-stream parse against the recorded transcript" do
      assert_profile_conformance(:codex,
        prompt: "fix the failing test",
        opts: [model: "gpt-5-codex"],
        expected_argv: ["exec", "fix the failing test", "--json", "--model", "gpt-5-codex"],
        transcript: "harness/codex_exec.jsonl",
        expected_parse: %{
          result: "Made the failing unit test pass.",
          # turn.completed usage: input 1200 + cached_input 900 + output 300.
          tokens: 2400,
          cost: %{tokens: 2400}
        }
      )
    end

    test "argv without a model omits the --model flag (same recorded parse)" do
      assert_profile_conformance(:codex,
        prompt: "fix the failing test",
        opts: [],
        expected_argv: ["exec", "fix the failing test", "--json"],
        transcript: "harness/codex_exec.jsonl",
        expected_parse: %{
          result: "Made the failing unit test pass.",
          tokens: 2400,
          cost: %{tokens: 2400}
        }
      )
    end
  end

  describe ":antigravity golden-transcript conformance (T14.3, ADR-0022)" do
    # The #76 non-TTY workaround: argv carries the prompt via --prompt-file (the
    # CliAdapter materializes the temp file and threads its path as
    # opts[:prompt_file]), NEVER the bare -p/--prompt that drops stdout under a
    # non-TTY subprocess. The conformance helper hands opts straight to build_args,
    # so the case supplies the temp path explicitly. The recorded prompt argument
    # is intentionally absent from the argv (it travels via the file).
    test "argv uses --prompt-file + --output json --yes + parses the JSON envelope" do
      assert_profile_conformance(:antigravity,
        prompt: "fix the failing test",
        opts: [prompt_file: "/tmp/kazi-prompt-1.txt", model: "gemini-2.5-pro"],
        expected_argv: [
          "run",
          "--prompt-file",
          "/tmp/kazi-prompt-1.txt",
          "--output",
          "json",
          "--yes",
          "--model",
          "gemini-2.5-pro"
        ],
        transcript: "harness/antigravity_run.json",
        expected_parse: %{
          # usage: input 1500 + output 400.
          result: "Made the failing unit test pass.",
          tokens: 1900,
          cost: %{tokens: 1900}
        }
      )
    end

    test "argv without a model omits the --model flag (same recorded parse)" do
      assert_profile_conformance(:antigravity,
        prompt: "fix the failing test",
        opts: [prompt_file: "/tmp/kazi-prompt-2.txt"],
        expected_argv: [
          "run",
          "--prompt-file",
          "/tmp/kazi-prompt-2.txt",
          "--output",
          "json",
          "--yes"
        ],
        transcript: "harness/antigravity_run.json",
        expected_parse: %{
          result: "Made the failing unit test pass.",
          tokens: 1900,
          cost: %{tokens: 1900}
        }
      )
    end

    # NEVER the bug-prone bare-prompt form: the argv must not contain -p/--prompt.
    test "argv NEVER uses the bare -p/--prompt that drops stdout under a non-TTY (#76)" do
      profile = Registry.fetch!(:antigravity)
      argv = Profile.build_args(profile, "do the thing", prompt_file: "/tmp/p.txt")

      refute "-p" in argv
      refute "--prompt" in argv
      assert "--prompt-file" in argv
      assert ["--output", "json"] -- argv == []
      assert "--yes" in argv
    end
  end

  describe ":claw golden-transcript conformance (T14.4, ADR-0022) — BEST-EFFORT" do
    # claw-code is DEMO-GRADE: it emits NO JSON, so its "golden transcript" is just
    # the RAW stdout text the tool printed, and `parse` surfaces it verbatim as
    # :result with NO cost/token extraction (the structured-output bar it does not
    # meet). The fixture carries the recorded trailing newline, so :result keeps it.
    test "argv is the bare `prompt <prompt>` and parse returns the RAW stdout as :result" do
      assert_profile_conformance(:claw,
        prompt: "fix the failing test",
        opts: [],
        expected_argv: ["prompt", "fix the failing test"],
        transcript: "harness/claw_prompt.txt",
        # The whole recorded stdout (trailing newline included) is the :result, and
        # NOTHING structured (no tokens/cost) is invented.
        expected_parse: %{result: "Made the failing unit test pass.\n"}
      )
    end

    test "opts are ignored — claw has no model flag (argv unchanged, same raw parse)" do
      assert_profile_conformance(:claw,
        prompt: "fix the failing test",
        opts: [model: "ignored-by-claw"],
        expected_argv: ["prompt", "fix the failing test"],
        transcript: "harness/claw_prompt.txt",
        expected_parse: %{result: "Made the failing unit test pass.\n"}
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

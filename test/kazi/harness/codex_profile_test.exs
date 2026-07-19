defmodule Kazi.Harness.CodexProfileTest do
  # T14.2 (UC-032, ADR-0022): the built-in :codex harness profile — argv
  # assembly for `codex exec <prompt> --json [--model …]` and parsing of Codex's
  # JSONL event stream (`thread.started`/`item.*`/`turn.completed`).
  #
  # Codex is the priority fully-conformant addition; its parser MIRRORS the
  # opencode NDJSON path. Unlike opencode there is no checked-in stub binary, so
  # these tests drive the profile's pure functions directly: build_args via the
  # Profile API, and the JSONL parser against literal sample streams (the same
  # bytes the generic CliAdapter would hand it). The golden-transcript fixture
  # case lives in conformance_test.exs; this file covers the unit-level edges.
  #
  # async: true — purely pure functions + checked-in data, no OS env or disk.
  use ExUnit.Case, async: true

  alias Kazi.Harness.{Profile, Registry}

  describe "Registry lookup" do
    test "fetch(:codex) returns the codex profile" do
      assert {:ok, %Profile{id: :codex, command: "codex"} = profile} = Registry.fetch(:codex)

      assert is_function(profile.build_args, 2)
      assert is_function(profile.parse, 1)
      # :model is declared so resolution forwards it; Claude-only hygiene flags
      # are NOT in supported_opts, so they are never passed to codex.
      assert :model in profile.supported_opts
      assert :command in profile.supported_opts
      refute :max_budget_usd in profile.supported_opts
      refute :permission_mode in profile.supported_opts
    end

    test "fetch!/1 returns the profile and ids/0 lists :codex alongside the others" do
      assert %Profile{id: :codex} = Registry.fetch!(:codex)
      assert :codex in Registry.ids()
      assert :claude in Registry.ids()
      assert :opencode in Registry.ids()
    end
  end

  describe ":codex argv (Profile.build_args/3)" do
    test "with a model: exec <prompt> --json --model <m>" do
      profile = Registry.fetch!(:codex)

      assert Profile.build_args(profile, "do X", model: "gpt-5-codex") ==
               ["exec", "do X", "--json", "--model", "gpt-5-codex"]
    end

    test "without a model: just exec <prompt> --json" do
      profile = Registry.fetch!(:codex)

      assert Profile.build_args(profile, "do X", []) == ["exec", "do X", "--json"]
    end

    test "an empty-string model is treated as no model (no --model flag)" do
      profile = Registry.fetch!(:codex)

      assert Profile.build_args(profile, "do X", model: "") == ["exec", "do X", "--json"]
    end

    test "a non-string model is ignored (no --model flag)" do
      profile = Registry.fetch!(:codex)

      assert Profile.build_args(profile, "do X", model: nil) == ["exec", "do X", "--json"]
    end
  end

  describe ":codex JSONL parse (Profile.parse/2)" do
    test "carries the final agent text and summed usage from a turn.completed" do
      profile = Registry.fetch!(:codex)

      stream =
        Enum.join(
          [
            ~s({"type":"thread.started","thread_id":"th_a"}),
            ~s({"type":"item.completed","item":{"type":"agent_message","text":"Made the failing unit test pass."}}),
            ~s({"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":900,"output_tokens":300}})
          ],
          "\n"
        )

      parsed = Profile.parse(profile, stream)

      assert parsed.result == "Made the failing unit test pass."
      # input 1200 + cached_input 900 + output 300.
      assert parsed.tokens == 1200 + 900 + 300
      assert parsed.cost == %{tokens: 2400}

      # T34.2 (ADR-0046): the SAME usage object maps onto the economy envelope
      # (Codex reports the cached/fresh split natively), the raw object is kept,
      # and all three fields reported -> :full fidelity.
      assert parsed.usage == %{input_tokens: 1200, cached_input_tokens: 900, output_tokens: 300}

      assert parsed.usage_raw == %{
               "input_tokens" => 1200,
               "cached_input_tokens" => 900,
               "output_tokens" => 300
             }

      assert parsed.usage_fidelity == :full
    end

    test "T34.2: a usage object reporting only SOME fields maps to :partial (absent ≠ zero)" do
      profile = Registry.fetch!(:codex)

      # Only cached_input_tokens reported — the cached-read class the economy
      # program centers on. The other two fields are OMITTED, not zero-filled.
      stream =
        Enum.join(
          [
            ~s({"type":"item.completed","item":{"type":"agent_message","text":"done"}}),
            ~s({"type":"turn.completed","usage":{"cached_input_tokens":900}})
          ],
          "\n"
        )

      parsed = Profile.parse(profile, stream)

      assert parsed.usage == %{cached_input_tokens: 900}
      refute Map.has_key?(parsed.usage, :input_tokens)
      refute Map.has_key?(parsed.usage, :output_tokens)
      assert parsed.usage_raw == %{"cached_input_tokens" => 900}
      assert parsed.usage_fidelity == :partial
    end

    test "accepts the assistant_message alias for the agent text item" do
      profile = Registry.fetch!(:codex)

      stream =
        ~s({"type":"item.completed","item":{"type":"assistant_message","text":"answer"}})

      assert Profile.parse(profile, stream).result == "answer"
    end

    test "last agent message wins as :result across multiple item events" do
      profile = Registry.fetch!(:codex)

      stream =
        Enum.join(
          [
            ~s({"type":"item.updated","item":{"type":"agent_message","text":"working on it"}}),
            ~s({"type":"item.completed","item":{"type":"agent_message","text":"final answer"}})
          ],
          "\n"
        )

      assert Profile.parse(profile, stream).result == "final answer"
    end

    test "last turn.completed usage wins (incremental then final)" do
      profile = Registry.fetch!(:codex)

      stream =
        Enum.join(
          [
            ~s({"type":"turn.completed","usage":{"input_tokens":5,"cached_input_tokens":0,"output_tokens":1}}),
            ~s({"type":"item.completed","item":{"type":"agent_message","text":"done"}}),
            ~s({"type":"turn.completed","usage":{"input_tokens":700,"cached_input_tokens":2000,"output_tokens":120}})
          ],
          "\n"
        )

      parsed = Profile.parse(profile, stream)

      assert parsed.result == "done"
      # Final usage wins: 700 + 2000 + 120.
      assert parsed.tokens == 700 + 2000 + 120
      assert parsed.cost == %{tokens: 2820}
    end

    test "reasoning/command items contribute no :result (only agent_message does)" do
      profile = Registry.fetch!(:codex)

      stream =
        Enum.join(
          [
            ~s({"type":"item.started","item":{"type":"reasoning","text":"thinking"}}),
            ~s({"type":"item.completed","item":{"type":"command_execution","command":"mix test","exit_code":0}})
          ],
          "\n"
        )

      assert Profile.parse(profile, stream) == %{}
    end

    test "when no usage is reported, token keys are OMITTED (no fabrication)" do
      profile = Registry.fetch!(:codex)

      stream =
        ~s({"type":"item.completed","item":{"type":"agent_message","text":"done, no usage"}})

      parsed = Profile.parse(profile, stream)

      assert parsed.result == "done, no usage"
      refute Map.has_key?(parsed, :tokens)
      refute Map.has_key?(parsed, :cost)
      # T34.2: a parsed turn with NO usage reports :none — not zero-filled fields,
      # and no :usage/:usage_raw at all (absent ≠ zero, ADR-0046 honest-unknown).
      assert parsed.usage_fidelity == :none
      refute Map.has_key?(parsed, :usage)
      refute Map.has_key?(parsed, :usage_raw)
    end

    test "malformed/empty output degrades to %{} (additive, never crashes)" do
      profile = Registry.fetch!(:codex)

      assert Profile.parse(profile, "") == %{}
      assert Profile.parse(profile, "not json at all\nstill not json") == %{}
      # A valid-but-irrelevant event yields nothing extractable.
      assert Profile.parse(profile, ~s({"type":"thread.started","thread_id":"th_x"})) == %{}
    end
  end
end
